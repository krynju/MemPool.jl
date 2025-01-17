"""
# Storage System Design

## Overview

MemPool implements a data storage system for allowing automated transfers of
DRef-associated data to storage media. The storage system is designed for the
"swap-to-disk" use case, where some portion of data is kept on-disk, and
swapped into memory as-needed, to support out-of-core operations. The storage
system is designed to be performant, flexible, and user-configurable, allowing
all kinds of definitions of "disk" to be implemented (including network stores,
tape drives, etc.).

The storage system is rooted on two abstract types, the `StorageResource`, and
the `StorageDevice`. Briefly, a `StorageResource` represents some finite
storage medium (such as a hard disk-backed filesystem, an S3 bucket, etc.),
while a `StorageDevice` represents a mechanism by which data can be written to
and read from an associated `StorageResource`. For example, the built-in
`FilesystemResource` is a `StorageResource` which represents a mounted
filesystem, while the `SerializationFileDevice` is a `StorageDevice` which can
store data on a `FilesystemResource` as a set of files written using the
`Serialization` stdlib format. Other `StorageResource`s and `StorageDevice`s
may be implemented by libraries or users to suit the specific storage medium
and use case.

All DRefs have an associated `StorageDevice`, which manages the reference's
data. The global device is available at `GLOBAL_DEVICE[]`, and may be
set by the user to whatever device is most desirable as a default. When a DRef
is created with `poolset`, a "root" `StorageDevice` will be associated which
manages the reference's data, either directly, or indirectly by managing other
`StorageDevice`s. For example, the built-in `SimpleRecencyAllocator` can use assigned as
the root device to manage a `CPURAMDevice` and a `SerializationFileDevice` to
provide automatic swap-to-disk in a least-recently-used fashion.

## Entrypoints

The entrypoints of the storage system are:
- `poolset` - Writes the data at DRef creation time
- `poolget` - Reads the data to return it to the caller
- GC finalization - Unaccessible DRefs cause the data to be deleted

The associated internal storage functions are (respectively):
- `write_to_device!` - Writes the data from memory to the device
- `read_from_device` - Reads the data into memory from the device
- `delete_from_device!` - Deletes the data from the device
- `retain_on_device!` - Controls whether data is retained on device upon deletion

The internal storage functions don't map exactly to the entrypoints; a
`poolget` might require writing some unrelated data from memory to disk before
the desired data can be read from disk to memory, and both existing data
locations will then probably need to be deleted to minimize storage usage.

## Internal Consistency

To allow for concurrent storage operations on unrelated data, the storage
system uses a set of locks and atomics/read-copy-update to ensure safe and
consistent access to data, while minimizing unnecessary wait time.

Globally, the datastore maintains a single lock that protects access to the
mapping from DRef ID to the associated `RefState` object. The `RefState` object
contains everything necessary to access and manipulate the DRef's data, and the
object is maintained for the lifetime of the DRef, allowing it to be cached and
threaded through function to minimize datastore lock contention. This globally
datastore lock is thus a short point of contention which should only rarely
need to be accessed (ideally only once, and very briefly, per storage
entrypoint).

The `RefState` object contains some basic information about the data, including
its estimated size in memory. Most importantly, it also points to a
`StorageState` object, which contains all of the information relevant to
storing and retrieving the data. The `StorageState` field of `RefState` is
atomically accessed, ensuring it always points to a valid object.

The `StorageState` itself contains fields for the root device, the "leaf"
devices (the devices which physically performs reads/writes/deletes), the
in-memory data (if any), and the on-device data (if any). The `StorageState`'s
fields are not always safe to access; thus, they are protected by a field
containing a `Base.Event`, which indicates when the other fields are safe to
access. Once the event has been notified, all other fields may be safely read
from. Any `getproperty` call to a `StorageState` field waits on this event to
complete, which ensures that all in-flight operations have completed.

In order to transition data to-and-from memory and disk, the `StorageState`
contained in the `RefState` can be atomically swapped with a new one which
represents the new state of the DRef's data. Making such a transition occurs
with the `storage_rcu!` helper, which can safely construct a new
`StorageState`, and install it as the new "source of truth". This helper uses
the read-copy-update pattern, or RCU, to ensure that new `StorageState` is
always based on the existing `StorageState`. Pairing with this helper is
`storage_read`, which can safely read the current `StorageState` from its
`RefState`.

This setup allows devices to safely determine the current state of a DRef's
data, and to ensure that all readers can see a fully-formed `StorageState`
object. This also makes it easy to ensure that data is never accidentally lost
by two conflicting transitions. However, it is important to note that by the
time a field of a read `StorageState` is accessed, the current state of the
DRef's data may have changed. This is not normally something to worry about;
whatever `StorageState` was just read can treated as the (temporary) source of
truth. Of course, `StorageState`s should thus never be cached or reused, as
they can quickly become stale, and doing so might preserve excessive data.

This system also has the benefit of providing concurrent and lazy storage
operations; the `StorageState` for a `RefState` may be transitioned before the
actual data transfer completes, and synchronization will only occur when the
`StorageState` is later accessed. And any two tasks which operate on different
DRefs (and which have their associated `RefState`s available) may never content
with each other.

## Queries

MemPool provides utilities to query `StorageResource`s and `StorageDevice`s for
their capacity and current utilization. The `storage_capacity`,
`storage_utilization`, and `storage_available` utilities work as expected on
`StorageResource` objects, and return values in bytes. Additionally, because
`StorageDevice`s can access multiple `StorageResource`s, the same utilities can
also be optionally passed a `StorageResource` object to limit queries to that
specific resource.

## Limits and Limitations

Devices like the `SimpleRecencyAllocator` set byte limits on how much data may
reside in memory and on disk. These limits are, unfortunately, not exact or
guaranteed, because of the nature of Julia's GC, and an inability of MemPool to
intercept user allocations. Thus, the ability of such devices to manage memory
or report the correct amount of storage media utilization is limited, and
should be taken as an approximation.

Additionally, leaf devices may report a storage utilization level that varies
according to external forces, such as by allocations from other processes on
the system, or fluctuations in OS memory management. The `externally_varying`
query on a `StorageDevice` will return `true` if the device is subject to such
unpredictable variation. A result of `false` implies that the device is not
aware of such variation, and lives in an "ideal world" where the device fully
controls all storage variations; of course, this is an approximation of
reality, and does not actually reflect how much of the physical resources are
truly available.
"""

include("fsinfo.jl")

"""
    StorageResource

The supertype for all storage resources. Any subtype represents some storage
hardware or modality (RAM, disk, NAS, VRAM, tape, etc.) where data can be
stored, and which has some current usage level and a maximum capacity (both
measures in bytes).

Storage resources are generally unique (although they may alias), and do not
represent a method of storing/loading data to/from the resource; instead, a
`StorageDevice` provides an actual implementation of such operations on one or
more resources.
"""
abstract type StorageResource end
storage_available(::StorageResource) = 0
storage_capacity(::StorageResource) = 0
storage_utilized(s::StorageResource) = storage_capacity(s) - storage_available(s)

"Represents CPU RAM."
struct CPURAMResource <: StorageResource end
if Sys.islinux()
function storage_available(::CPURAMResource)
    open("/proc/meminfo", "r") do io
        # skip first 2 lines
        readline(io)
        readline(io)
        line = readline(io)
        free = match(r"MemAvailable:\s*([0-9]*)\s.*", line).captures[1]
        parse(UInt64, free) * 1024
    end
end
else
# FIXME: Sys.free_memory() includes OS caches
storage_available(::CPURAMResource) = Sys.free_memory()
end
storage_capacity(::CPURAMResource) = Sys.total_memory()

"Represents a filesystem mounted at a given path."
struct FilesystemResource <: StorageResource
    mountpoint::String
end
FilesystemResource() = FilesystemResource(Sys.iswindows() ? "C:" : "/")
storage_available(s::FilesystemResource) = disk_stats(s.mountpoint).available
storage_capacity(s::FilesystemResource) = disk_stats(s.mountpoint).capacity

"""
    StorageDevice

The abstract supertype of all storage devices. A `StorageDevice` must implement
`movetodevice!`, `read_from_device`, and `delete_from_device!`. A `StorageDevice`
may reflect a mechanism for storing data on persistent storage, or it may be an
allocator which manages other `StorageDevice`s.

See the `SerializationFileDevice` for an example of how to implement a data
store.

When implementing an allocator, it's recommended to provide options that users
can tune to control how many bytes of storage may be used for each managed
`StorageDevice`. This makes it easier for users to predict the amount of
storage that a given piece of code can use. See the `SimpleRecencyAllocator`
for a (relatively) simple example of how to implement an allocator.
"""
abstract type StorageDevice end

# TODO: Docstrings
storage_available(dev::StorageDevice) = sum(res->storage_available(dev, res), storage_resources(dev))
storage_capacity(dev::StorageDevice) = sum(res->storage_capacity(dev, res), storage_resources(dev))
storage_utilized(dev::StorageDevice) = sum(res->storage_utilized(dev, res), storage_resources(dev))
check_same_resource(dev::StorageDevice, expected::StorageResource, res::StorageResource) =
    (expected === res) || throw(ArgumentError("Invalid storage resource $res for device $dev"))
storage_available(dev::StorageDevice, res::StorageResource) =
    throw(ArgumentError("Invalid storage resource $res for device $dev"))
storage_capacity(dev::StorageDevice, res::StorageResource) =
    throw(ArgumentError("Invalid storage resource $res for device $dev"))
storage_utilized(dev::StorageDevice, res::StorageResource) =
    throw(ArgumentError("Invalid storage resource $res for device $dev"))

mutable struct StorageLeaf
    # A low-level storage device
    device::StorageDevice
    # The handle associated with the device
    handle::Union{Some{Any}, Nothing}
    # Whether to retain the underlying data
    retain::Bool
end
StorageLeaf(device, handle) = StorageLeaf(device, handle, false)
StorageLeaf(device) = StorageLeaf(device, nothing, false)

"Safely copies a `Vector{StorageLeaf}` for later mutation."
copy_leaves(leaves::Vector{StorageLeaf}) =
    StorageLeaf[StorageLeaf(leaf.device, leaf.handle, leaf.retain) for leaf in leaves]

mutable struct StorageState
    # The in-memory value of the reference
    data::Union{Some{Any}, Nothing}
    # The low-level devices and handles physically storing the reference's values
    leaves::Vector{StorageLeaf}
    # The high-level device managing the reference's values
    root::StorageDevice
    # Notifies waiters when all fields become useable
    ready::Base.Event
end
StorageState(data, leaves, root) =
    StorageState(data, leaves, root, Base.Event())
StorageState(old::StorageState;
             data=old.data,
             leaves=old.leaves,
             root=old.root) = StorageState(data, leaves, root,
                                           Base.Event())

function Base.getproperty(sstate::StorageState, field::Symbol)
    if field == :ready
        return getfield(sstate, :ready)
    end

    wait(sstate.ready)
    return getfield(sstate, field)
end
Base.notify(sstate::StorageState) = notify(sstate.ready)
Base.wait(sstate::StorageState) = wait(sstate.ready)

mutable struct RefState
    # The storage state associated with the reference and its values
    @atomic storage::StorageState
    # The estimated size that the values of the reference take in memory
    size::UInt64
end
function Base.getproperty(state::RefState, field::Symbol)
    if field === :storage
        throw(ArgumentError("Cannot directly read :storage field of RefState\nUse storage_read(state) instead"))
    end
    return getfield(state, field)
end
function Base.setproperty!(state::RefState, field::Symbol, value)
    if field === :storage
        throw(ArgumentError("Cannot directly write :storage field of RefState\nUse storage_rcu!(f, state) instead"))
    end
    return setfield!(state, field, value)
end
Base.show(io::IO, state::RefState) =
    print(io, "RefState(size=$(Base.format_bytes(state.size)))")

"Returns the size of the data for reference `id`."
storage_size(ref::DRef) =
    (@assert ref.owner == myid(); storage_size(ref.id))
storage_size(id::Int) =
    storage_size(with_lock(()->datastore[id], datastore_lock))
storage_size(state::RefState) = state.size

"""
    write_to_device!(device::StorageDevice, state::RefState, id::Int)

Writes reference `id`'s data to `device`. Reads the data into memory first (via
`read_from_device(CPURAMDevice(), id)`) if necessary.
"""
function write_to_device! end
write_to_device!(state::RefState, ref::DRef) =
    write_to_device!(storage_read(state).root, state, ref.id)
write_to_device!(device::StorageDevice, ref::DRef) =
    write_to_device!(device, with_lock(()->datastore[ref.id], datastore_lock), ref.id)
write_to_device!(device::StorageDevice, state::RefState, ref::DRef) =
    write_to_device!(device, state, ref.id)
write_to_device!(state::RefState, id::Int) =
    write_to_device!(storage_read(state).root, state, id)
write_to_device!(device::StorageDevice, id::Int) =
    write_to_device!(device, with_lock(()->datastore[id], datastore_lock), id)

"""
    read_from_device(device::StorageDevice, state::RefState, id::Int, ret::Bool) -> Any

Access the value of reference `id` from `device`, and return it if `ret` is
`true`; if `ret` is `false`, then the value is not actually retrieved, but
internal counters may be updated to account for this access. Also ensures that
the values for reference `id` are in memory; if necessary, they will be read
from the reference's true storage device.
"""
function read_from_device end
read_from_device(state::RefState, ref::DRef, ret::Bool) =
    read_from_device(storage_read(state).root, state, ref.id, ret)
read_from_device(device::StorageDevice, ref::DRef, ret::Bool) =
    read_from_device(device, with_lock(()->datastore[ref.id], datastore_lock), ref.id, ret)
read_from_device(device::StorageDevice, state::RefState, ref::DRef, ret::Bool) =
    read_from_device(device, state, ref.id, ret)
read_from_device(state::RefState, id::Int, ret::Bool) =
    read_from_device(storage_read(state).root, state, id, ret)
read_from_device(device::StorageDevice, id::Int, ret::Bool) =
    read_from_device(device, with_lock(()->datastore[id], datastore_lock), id, ret)

"""
    delete_from_device!(device::StorageDevice, state::RefState, id::Int)

Delete reference `id`'s data from `device`, such that upon return, the space
used by the previously-referenced data is now available for allocating to other
data.
"""
function delete_from_device! end
delete_from_device!(state::RefState, ref::DRef) =
    delete_from_device!(storage_read(state).root, state, ref.id)
delete_from_device!(device::StorageDevice, ref::DRef) =
    delete_from_device!(device, with_lock(()->datastore[ref.id], datastore_lock), ref.id)
delete_from_device!(device::StorageDevice, state::RefState, ref::DRef) =
    delete_from_device!(device, state, ref.id)
delete_from_device!(state::RefState, id::Int) =
    delete_from_device!(storage_read(state).root, state, id)
delete_from_device!(device::StorageDevice, id::Int) =
    delete_from_device!(device, with_lock(()->datastore[id], datastore_lock), id)

"""
    retain_on_device!(device::StorageDevice, state::RefState, id::Int, retain::Bool; all::Bool=false)

Sets the retention state of reference `id` for `device`. If `retain` is `false`
(the default when references are created), then data will be deleted from
`device` upon a call to `delete_from_device!`; if `retain` is `true`, then the
data will continue to exist on the device (if possible) upon a call to
`delete_from_device!`.

If the `all` kwarg is set to `true`, then any registered leaf devices will have
their retain value set to `retain`.

    retain_on_device!(device::StorageDevice, retain::Bool)

Sets the retention state of all references stored on `device` (if possible).
"""
function retain_on_device! end
retain_on_device!(state::RefState, ref::DRef, retain::Bool; kwargs...) =
    retain_on_device!(storage_read(state).root, state, ref.id, retain; kwargs...)
retain_on_device!(device::StorageDevice, ref::DRef, retain::Bool; kwargs...) =
    retain_on_device!(device, with_lock(()->datastore[ref.id], datastore_lock), ref.id, retain; kwargs...)
retain_on_device!(device::StorageDevice, state::RefState, ref::DRef, retain::Bool; kwargs...) =
    retain_on_device!(device, state, ref.id, retain; kwargs...)
retain_on_device!(state::RefState, id::Int, retain::Bool; kwargs...) =
    retain_on_device!(storage_read(state).root, state, id, retain; kwargs...)
retain_on_device!(device::StorageDevice, id::Int, retain::Bool; kwargs...) =
    retain_on_device!(device, with_lock(()->datastore[id], datastore_lock), id, retain; kwargs...)
function retain_on_device!(device::StorageDevice, state::RefState, id::Int, retain::Bool; all=false)
    notify(storage_rcu!(state) do sstate
        devices = if all && device === sstate.root
            map(l->l.device, sstate.leaves)
        else
            [device]
        end
        leaves = copy_leaves(sstate.leaves)
        for device in devices
            idx = findfirst(l->l.device === device, leaves)
            if idx === nothing
                throw(ArgumentError("Invalid device $device"))
            end
            leaf = leaves[idx]
            leaves[idx] = StorageLeaf(leaf.device, leaf.handle, retain)
        end
        return StorageState(sstate; leaves)
    end)
    return
end

retain_on_device!(device::StorageDevice, retain::Bool) = nothing

"""
    externally_varying(device::StorageDevice) -> Bool

Indicates whether the storage availability or capacity of device `device may
vary according to external forces, such as other unrelated processes or OS
behavior.

When `true`, this implies that the ability of `device to store data is
completely arbitrary. Typically this means that calls to storage availability
queries can return different results, even if no storage calls have been made
on `device.

When `false`, it may be reasonable to assume that exact accounting of storage
availability is possible, although it is not guaranteed. There are also no
guarantees that allocations will not trigger forced OS memory reclamation (such
as by the Linux OOM killer).
"""
externally_varying(::StorageDevice) = true

"""
    CPURAMDevice <: StorageDevice

Stores data in memory. This is the default device.
"""
struct CPURAMDevice <: StorageDevice end
storage_resources(dev::CPURAMDevice) = Set{StorageResource}([CPURAMResource()])
storage_capacity(::CPURAMDevice, res::CPURAMResource) = storage_capacity(res)
storage_capacity(::CPURAMDevice) = storage_capacity(CPURAMResource())
storage_available(::CPURAMDevice, res::CPURAMResource) = storage_available(res)
storage_available(::CPURAMDevice) = storage_available(CPURAMResource())
storage_utilized(::CPURAMDevice, res::CPURAMResource) = storage_utilized(res)
storage_utilized(::CPURAMDevice) = storage_utilized(CPURAMResource())
function write_to_device!(device::CPURAMDevice, state::RefState, ref_id::Int)
    sstate = storage_read(state)
    if sstate.data === nothing
        data = read_from_device(first(sstate.leaves).device, state, ref_id, true)
        notify(storage_rcu!(state) do sstate
            StorageState(sstate; data=Some{Any}(data))
        end)
    end
    return
end
function read_from_device(::CPURAMDevice, state::RefState, ref_id::Int, ret::Bool)
    if ret
        sstate = storage_read(state)
        if sstate.data === nothing
            # TODO: @assert !(sstate.leaf isa CPURAMDevice) "Data lost!"
            return read_from_device(first(sstate.leaves).device, state, ref_id, true)
        end
        return something(sstate.data)
    end
end
function delete_from_device!(::CPURAMDevice, state::RefState, ref_id::Int)
    notify(storage_rcu!(state) do sstate
        StorageState(sstate; data=nothing)
    end)
    return
end

"""
    SerializationFileDevice <: StorageDevice

Stores data in a temporary file, using the `Serialization` stdlib to serialize
and deserialize data. Also supports optional ser/des filtering stages, such as
for compression or encryption.
"""
struct SerializationFileDevice <: StorageDevice
    fs::FilesystemResource
    dir::String
    filters::Vector{Pair}
end
"Construct a `SerializationFileDevice` which stores data in the directory `dir`."
SerializationFileDevice(fs, dir; filters=Pair[]) =
    SerializationFileDevice(fs, dir, filters)
SerializationFileDevice(dir; filters=Pair[]) =
    SerializationFileDevice(FilesystemResource(Sys.iswindows() ? "C:" : "/"), dir, filters)
SerializationFileDevice(; filters=Pair[]) =
    SerializationFileDevice(joinpath(tempdir(), ".mempool"); filters)
storage_resources(dev::SerializationFileDevice) = Set{StorageResource}([dev.fs])
function storage_capacity(dev::SerializationFileDevice, res::FilesystemResource)
    check_same_resource(dev, dev.fs, res)
    storage_capacity(res)
end
storage_capacity(dev::SerializationFileDevice) = storage_capacity(dev.fs)
function storage_available(dev::SerializationFileDevice, res::FilesystemResource)
    check_same_resource(dev, dev.fs, res)
    storage_available(res)
end
storage_available(dev::SerializationFileDevice) = storage_available(dev.fs)
function storage_utilized(dev::SerializationFileDevice, res::FilesystemResource)
    check_same_resource(dev, dev.fs, res)
    return storage_capacity(dev, res) - storage_available(dev, res)
end
storage_utilized(dev::SerializationFileDevice) =
    storage_capacity(dev, dev.fs) - storage_available(dev, dev.fs)
function write_to_device!(device::SerializationFileDevice, state::RefState, ref_id::Int)
    mkpath(device.dir)
    path = tempname(device.dir; cleanup=false)
    fref = FileRef(path, state.size)
    sstate = storage_read(state)
    data = sstate.data
    if data === nothing
        data = read_from_device(first(sstate.leaves).device, state, ref_id, true)
    else
        data = something(data)
    end
    leaf = StorageLeaf(device)
    sstate = storage_rcu!(state) do sstate
        StorageState(sstate; leaves=vcat(sstate.leaves, leaf))
    end
    errormonitor(Threads.@spawn begin
        open(path, "w") do io
            for (write_filt, ) in reverse(device.filters)
                io = write_filt(io)
            end
            serialize(io, MMWrap(data))
            close(io)
        end
        leaf.handle = Some{Any}(fref)
        notify(sstate)
    end)
    return
end
function read_from_device(device::SerializationFileDevice, state::RefState, id::Int, ret::Bool)
    sstate = storage_read(state)
    data = sstate.data
    if data !== nothing
        ret && return something(data)
        return
    end
    idx = findfirst(l->l.device === device, sstate.leaves)
    fref = something(sstate.leaves[idx].handle)
    sstate = storage_rcu!(state) do sstate
        StorageState(sstate)
    end
    errormonitor(Threads.@spawn begin
        data = open(fref.file, "r+") do io
            for (_, read_filt) in reverse(device.filters)
                io = read_filt(io)
            end
            unwrap_payload(deserialize(io))
        end
        sstate.data = Some{Any}(data)
        notify(sstate)
    end)
    if ret
        return something(sstate.data)
    end
end
function delete_from_device!(device::SerializationFileDevice, state::RefState, id::Int)
    sstate = storage_read(state)
    idx = findfirst(l->l.device === device, sstate.leaves)
    idx === nothing && return
    leaf = sstate.leaves[idx]
    fref = something(leaf.handle)
    notify(storage_rcu!(state) do sstate
        StorageState(sstate; leaves=filter(l->l.device !== device,
                                           sstate.leaves))
    end)
    if !leaf.retain
        errormonitor(Threads.@spawn begin
            rm(fref.file; force=true)
        end)
    end
    return
end

"""
    SimpleRecencyAllocator <: StorageDevice

A simple LRU allocator device which manages an `upper` device and a `lower`
device. The `upper` device is be limited to `upper_limit` bytes of storage;
when an allocation exceeds this limit, the least recently accessed data will be
moved to the `lower` device (which is unbounded), and the new allocation will
be moved to the `upper` device.

Consider using an `upper` device of `CPURAMDevice` and a `lower` device of
`SerializationFileDevice` to implement a basic swap-to-disk allocator. Such a
device will be created and used automatically if the environment variable
`JULIA_MEMPOOL_EXPERIMENTAL_FANCY_ALLOCATOR` is set to `1` or `true`.
"""
struct SimpleRecencyAllocator <: StorageDevice
    mem_limit::UInt64
    device::StorageDevice
    device_limit::UInt64
    policy::Symbol

    # Most recently used elements are always at the front
    mem_refs::Vector{Int}
    device_refs::Vector{Int}

    # Counters for Hit, Miss, Evict
    stats::Vector{Int}

    # Whether to retain all tracked refs
    retain::Base.RefValue{Bool}

    ref_cache::Dict{Int,RefState}
    lock::NonReentrantLock

    function SimpleRecencyAllocator(mem_limit, device, device_limit, policy; retain=false)
        mem_limit > 0 || throw(ArgumentError("Memory limit must be positive and non-zero: $mem_limit"))
        device_limit > 0 || throw(ArgumentError("Device limit must be positive and non-zero: $device_limit"))
        policy in (:LRU, :MRU) || throw(ArgumentError("Invalid recency policy: $policy"))
        return new(mem_limit, device, device_limit, policy,
                   Int[], Int[], zeros(Int, 3), Ref(retain),
                   Dict{Int,RefState}(), NonReentrantLock())
    end
end

function Base.show(io::IO, sra::SimpleRecencyAllocator)
    mem_res = CPURAMResource()
    mem_used = Base.format_bytes(storage_utilized(sra, mem_res))
    device_used = 0
    for res in storage_resources(sra.device)
        device_used += storage_utilized(sra, res)
    end
    device_used = Base.format_bytes(device_used)
    mem_limit = Base.format_bytes(sra.mem_limit)
    device_limit = Base.format_bytes(sra.device_limit)
    println(io, "SimpleRecencyAllocator(mem: $mem_used used ($mem_limit max), device: $device_used used ($device_limit max), policy: $(sra.policy))")
    print(io, "  Stats: $(sra.stats[1]) Hits, $(sra.stats[2]) Misses, $(sra.stats[3]) Evicts")
end

storage_resources(sra::SimpleRecencyAllocator) =
    Set{StorageResource}([CPURAMResource(), storage_resources(sra.device)...])
function storage_capacity(sra::SimpleRecencyAllocator, res::StorageResource)
    if res isa CPURAMResource
        return sra.mem_limit
    elseif res in storage_resources(sra.device)
        return sra.device_limit
    else
        throw(ArgumentError("Invalid storage resource $res for device $sra"))
    end
end
storage_capacity(sra::SimpleRecencyAllocator) = sra.mem_limit + sra.device_limit
storage_available(sra::SimpleRecencyAllocator, res::StorageResource) =
    storage_capacity(sra, res) - storage_utilized(sra, res)
storage_available(sra::SimpleRecencyAllocator) =
    storage_capacity(sra) - storage_utilized(sra)
function storage_utilized(sra::SimpleRecencyAllocator, res::StorageResource)
    if res isa CPURAMResource
        return with_lock(sra.lock) do
            sum(map(id->sra.ref_cache[id].size, sra.mem_refs))
        end
    elseif res in storage_resources(sra.device)
        return with_lock(sra.lock) do
            sum(map(id->sra.ref_cache[id].size, sra.device_refs))
        end
    else
        throw(ArgumentError("Invalid storage resource $res for device $sra"))
    end
end
storage_utilized(sra::SimpleRecencyAllocator) = with_lock(sra.lock) do
    sum(map(id->sra.ref_cache[id].size, sra.mem_refs)) +
    sum(map(id->sra.ref_cache[id].size, sra.device_refs))
end
function write_to_device!(sra::SimpleRecencyAllocator, state::RefState, ref_id::Int)
    with_lock(sra.lock) do
        sra.ref_cache[ref_id] = state
    end
    try
        if state.size > sra.mem_limit || state.size > sra.device_limit
            # Too bulky
            throw(ArgumentError("Cannot write ref $ref_id of size $(Base.format_bytes(state.size)) to LRU"))
        end
        sra_migrate!(sra, state, ref_id, true)
    catch err
        delete!(sra.ref_cache, ref_id)
        rethrow(err)
    end
    return
end
function sra_migrate!(sra::SimpleRecencyAllocator, state::RefState, ref_id, to_mem;
                      read=false, locked=false)
    ref_size = state.size
    if to_mem
        # Demoting to device
        from_refs = sra.mem_refs
        from_limit = sra.mem_limit
        from_device = CPURAMDevice()
        to_refs = sra.device_refs
        to_limit = sra.device_limit
        to_device = sra.device
    else
        # Promoting to memory
        from_refs = sra.device_refs
        from_limit = sra.device_limit
        from_device = sra.device
        to_refs = sra.mem_refs
        to_limit = sra.mem_limit
        to_device = CPURAMDevice()
    end
    from_size = 0
    to_size = 0
    idx = 0
    with_lock(sra.lock, !locked) do
        from_size = sum(map(id->sra.ref_cache[id].size, from_refs))
        to_size = sum(map(id->sra.ref_cache[id].size, to_refs))
        idx = if sra.policy == :LRU
            to_mem ? lastindex(from_refs) : firstindex(from_refs)
        else
            to_mem ? firstindex(from_refs) : lastindex(from_refs)
        end

        # Plan a batch of writes
        write_list = Int[]
        while ref_size + from_size > from_limit
            # Demote older/promote newer refs until space is available
            @assert 1 <= idx <= length(from_refs) "Failed to migrate $(Base.format_bytes(ref_size)) for ref $ref_id"
            oref = from_refs[idx]
            oref_size = sra.ref_cache[oref].size
            if oref_size + to_size <= to_limit
                # Destination has space for this ref
                push!(write_list, idx)
                from_size -= oref_size
                to_size += oref_size
            end
            idx += (to_mem ? -1 : 1) * (sra.policy == :LRU ? 1 : -1)
        end
        if isempty(write_list)
            @goto write_ref
        end

        # Initiate writes
        @sync for idx in write_list
            @inbounds sra.stats[3] += 1
            oref = from_refs[idx]
            oref_state = sra.ref_cache[oref]
            # N.B. We `write_to_device!` before deleting from old device, in case
            # the write fails (so we don't lose data)
            write_to_device!(to_device, oref_state, oref)
            @async delete_from_device!(from_device, oref_state, oref)
            @assert begin
                sstate = storage_read(oref_state)
                sstate.data !== nothing || any(l->l.handle !== nothing, sstate.leaves)
            end
        end

        # Update counters
        for oref in map(idx->from_refs[idx], write_list)
            push!(to_refs, oref)
            deleteat!(from_refs, findfirst(==(oref), from_refs))
        end

        # Space available, perform migration
        @label write_ref
        pushfirst!(from_refs, ref_id)
        write_to_device!(from_device, state, ref_id)

        # If we already had this ref, delete it from previous device
        if findfirst(x->x==ref_id, to_refs) !== nothing
            delete_from_device!(to_device, state, ref_id)
            deleteat!(to_refs, findfirst(x->x==ref_id, to_refs))
        end

        if read
            return read_from_device(from_device, state, ref_id, true)
        end
    end
end
function read_from_device(sra::SimpleRecencyAllocator, state::RefState, id::Int, ret::Bool)
    with_lock(sra.lock) do
        idx = findfirst(x->x==id, sra.mem_refs)
        if idx !== nothing
            @inbounds sra.stats[1] += 1
            deleteat!(sra.mem_refs, idx)
            pushfirst!(sra.mem_refs, id)
            return read_from_device(CPURAMDevice(), state, id, ret)
        end
        @assert id in sra.device_refs
        @inbounds sra.stats[2] += 1
        value = sra_migrate!(sra, state, id, true; read=true, locked=true)
        if ret
            return value
        end
    end
end
function delete_from_device!(sra::SimpleRecencyAllocator, state::RefState, id::Int)
    with_lock(sra.lock) do
        if (idx = findfirst(x->x==id, sra.mem_refs)) !== nothing
            if sra.retain[]
                # Migrate to device for retention
                sra_migrate!(sra, state, id, false; read=false, locked=true)
            else
                delete_from_device!(CPURAMDevice(), state, id)
                deleteat!(sra.mem_refs, idx)
                delete!(sra.ref_cache, id)
                return
            end
        end
        if (idx = findfirst(x->x==id, sra.device_refs)) !== nothing
            if sra.retain[]
                retain_on_device!(sra.device, state, sra.device_refs[idx], true)
            end
            delete_from_device!(sra.device, state, sra.device_refs[idx])
            deleteat!(sra.device_refs, idx)
            delete!(sra.ref_cache, id)
        end
    end
    return
end
function retain_on_device!(sra::SimpleRecencyAllocator, retain::Bool)
    with_lock(sra.lock) do
        # Retention will happen lazily, upon deletion
        sra.retain[] = retain
    end
end
externally_varying(::SimpleRecencyAllocator) = false

function set_device!(device::StorageDevice, state::RefState, id::Int)
    sstate = storage_read(state)
    old_device = sstate.root
    if old_device === device && findfirst(l->l.device === device, sstate.leaves) !== nothing
        return
    end
    write_to_device!(device, state, id)
    notify(storage_rcu!(state) do sstate
        StorageState(sstate; root=device)
    end)
    return
end
set_device!(device::StorageDevice, id::Int) =
    set_device!(device, with_lock(()->datastore[id], datastore_lock), id)
function set_device!(device::StorageDevice, ref::DRef)
    @assert ref.owner == myid()
    set_device!(device, ref.id)
end
function set_device!(device::StorageDevice, state::RefState, ref::DRef)
    @assert ref.owner == myid()
    set_device!(device, state, ref.id)
end

const GLOBAL_DEVICE = Ref{StorageDevice}(CPURAMDevice())
