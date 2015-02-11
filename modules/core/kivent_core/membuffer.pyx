# cython: profile=True
from cpython.mem cimport PyMem_Malloc, PyMem_Realloc, PyMem_Free
from cpython cimport bool


cdef class MemComponent:

    def __cinit__(self, MemoryBlock memory_block, unsigned int index,
            unsigned int offset):
        self._id = index + offset
        self.pointer = memory_block.get_pointer(index)


cdef class BlockIndex:

    def __cinit__(self, MemoryBlock memory_block, unsigned int offset,
        ComponentToCreate):
        cdef unsigned int count = memory_block.block_count
        self.block_objects = block_objects = []
        block_a = block_objects.append
        cdef unsigned int i
        for i in range(count):
            new_component = ComponentToCreate.__new__(ComponentToCreate, 
                memory_block, i, offset)
            block_a(new_component)

    property blocks:
        def __get__(self):
            return self.block_objects


cdef class PoolIndex:

    def __cinit__(self, MemoryPool memory_pool, ComponentToCreate, 
        start_offset):
        cdef unsigned int count = memory_pool.block_count
        cdef list blocks = memory_pool.memory_blocks
        self._block_indices = block_indices = []
        block_ind_a = block_indices.append
        cdef unsigned int i
        cdef unsigned int block_count
        cdef MemoryBlock block
        cdef unsigned int offset = start_offset
        for i in range(count):
            block = blocks[i]
            block_ind_a(BlockIndex(block, offset, ComponentToCreate))
            offset += block.block_count

    property block_indices:
        def __get__(self):
            return self._block_indices


cdef class ZoneIndex:

    def __cinit__(self, MemoryZone memory_zone, ComponentToCreate):
        cdef unsigned int count = memory_zone.reserved_count
        cdef dict pool_indices = {}
        cdef dict memory_pools = memory_zone.memory_pools
        cdef unsigned int offset = 0
        cdef unsigned int pool_count
        cdef unsigned int i
        self.memory_zone = memory_zone
        cdef MemoryPool pool
        for i in range(count):
            pool = memory_pools[i]
            pool_count = pool.count
            pool_indices[i] = PoolIndex(pool, ComponentToCreate, offset)
            offset += pool_count
        self._pool_indices = pool_indices

    property pool_indices:
        def __get__(self):
            return self._pool_indices

    def get_component_from_index(self, unsigned int index):
        pool_i, block_i, slot_i = self.memory_zone.get_pool_block_slot_indices(
            index)
        cdef PoolIndex pool_index = self._pool_indices[pool_i]
        cdef BlockIndex block_index = pool_index._block_indices[block_i]
        return block_index.block_objects[slot_i]


cdef class IndexedMemoryZone:
    
    def __cinit__(self, Buffer master_buffer, unsigned int block_size, 
        unsigned int component_size, dict reserved_spec, ComponentToCreate):
        cdef MemoryZone memory_zone = MemoryZone(block_size, 
            master_buffer, component_size, reserved_spec)
        cdef ZoneIndex zone_index = ZoneIndex(memory_zone, ComponentToCreate)
        self.zone_index = zone_index
        self.memory_zone = memory_zone

    def __getitem__(self, index):
        return self.zone_index.get_component_from_index(index)

    cdef void* get_pointer(self, unsigned int index):
        return self.memory_zone.get_pointer(index)

    def __getslice__(self, index_1, index_2):
        cdef ZoneIndex zone_index = self.zone_index
        get_component_from_index = zone_index.get_component_from_index
        return [get_component_from_index(i) for i in range(index_1, index_2)]


cdef class memrange:
    '''Use memrange to iterate a IndexedMemoryZone object and return
    the python active game entities, an active memory object is one that is
    either in use or previously used and now waiting in the free list.
    Memory objects that have never been allocated are skipped
    Args:

        memory_index IndexedMemoryZone

        start int

        end int

        zone str

        You must reference an IndexedMemoryZone, by default we will iterate
        through all the memory. The area of memory iterated can be controlled
        with options *start* and *end*, or you can provide the name of one of 
        the reserved zones to iterate that specific memory area.
    '''

    def __init__(self, IndexedMemoryZone memory_index, start=0, 
        end=None, zone=None):
        cdef MemoryZone memory_zone = memory_index.memory_zone
        cdef unsigned int zone_count = memory_zone.count
        self.memory_index = memory_index
        if zone is not None:
            start, end = memory_zone.get_pool_range(
                memory_zone.get_pool_index_from_name(zone))
        elif end > zone_count or end is None:
            end = zone_count
        self.start = start
        self.end = end

    def __iter__(self):
        return memrange_iter(self.memory_index, self.start, self.end)

cdef class memrange_iter:

    def __init__(self, IndexedMemoryZone memory_index, start, end):
        self.memory_index = memory_index
        self.current = start
        self.end = end

    def __iter__(self):
        return self

    def __next__(self):
        
        cdef IndexedMemoryZone memory_index = self.memory_index
        cdef MemoryZone memory_zone = memory_index.memory_zone
        cdef ZoneIndex zone_index = memory_index.zone_index
        cdef unsigned int current = self.current
        cdef unsigned int pool_index, used
        cdef void* pointer

        if current > self.end:
            raise StopIteration
        else:
            pool_index = memory_zone.get_pool_index_from_index(current)
            used = memory_zone.get_pool_end_from_pool_index(pool_index)
            if current >= used:
                self.current = memory_zone.get_start_of_pool(pool_index+1)
                return self.next()
            else:
                pointer = memory_zone.get_pointer(current)
                self.current += 1
                if <unsigned int>pointer == -1:
                    return self.next()
                return zone_index.get_component_from_index(current)


cdef class Buffer:

    def __cinit__(self, unsigned int size_in_blocks, 
        unsigned int size_of_blocks, unsigned int type_size):
        cdef unsigned int size_in_bytes = (
            size_in_blocks * size_of_blocks * 1024)
        self.used_count = 0
        self.data = NULL
        self.free_block_count = 0
        self.block_count = size_in_bytes // type_size
        self.size = size_in_blocks
        self.size_of_blocks = size_of_blocks * 1024
        self.real_size = size_in_bytes
        self.type_size = type_size
        self.free_blocks = []
        self.data_in_free = 0

    def __dealloc__(self):
        self.free_blocks = None
        self.block_count = 0
        self.free_block_count = 0
        self.deallocate_memory()

    cdef void allocate_memory(self):
        self.data = PyMem_Malloc(self.real_size)

    cdef void deallocate_memory(self):
        if self.data != NULL:
            PyMem_Free(self.data)

    cdef unsigned int add_data(self, unsigned int block_count) except -1:
        cdef unsigned int largest_free_block = 0
        cdef unsigned int index
        cdef unsigned int data_in_free = self.data_in_free
        cdef unsigned int tail_count = self.get_blocks_on_tail()
        if data_in_free >= block_count:
            largest_free_block = self.get_largest_free_block()
        if block_count <= largest_free_block:
            index = self.get_first_free_block_that_fits(block_count)
            self.data_in_free -= block_count
            self.free_block_count -= 1
        elif block_count <= tail_count:
            index = self.used_count
            self.used_count += block_count
        else:
            raise MemoryError()
        return index

    cdef void remove_data(self, unsigned int block_index, 
        unsigned int block_count):
        self.free_blocks.append((block_index, block_count))
        self.data_in_free += block_count
        self.free_block_count += 1
        if self.free_block_count == self.used_count:
            self.clear()

    cdef void* get_pointer(self, unsigned int block_index):
        cdef char* data = <char*>self.data
        return &data[block_index*self.size_of_blocks]

    cdef unsigned int get_largest_free_block(self):
        cdef unsigned int free_block_count = self.free_block_count
        cdef unsigned int i
        cdef tuple free_block
        cdef unsigned int index, block_count
        cdef list free_blocks = self.free_blocks
        cdef unsigned int largest_block_count = 0
        for i in range(free_block_count):
            free_block = free_blocks[i]
            index, block_count = free_block
            if block_count > largest_block_count:
                largest_block_count = block_count
        return largest_block_count

    cdef unsigned int get_first_free_block_that_fits(self, 
        unsigned int block_count):
        cdef unsigned int free_block_count = self.free_block_count
        cdef unsigned int i
        cdef tuple free_block
        cdef unsigned int index, free_block_size
        cdef list free_blocks = self.free_blocks
        cdef unsigned int new_block_count
        for i in range(free_block_count):
            free_block = free_blocks[i]
            index, free_block_size = free_block
            if block_count == free_block_size:
                free_blocks.pop(i)
                return index
            elif block_count < free_block_size:
                free_blocks.pop(i)
                new_block_count = free_block_size - block_count
                free_blocks.append((index+block_count, new_block_count))
                self.free_block_count += 1
                return index

    cdef unsigned int get_blocks_on_tail(self):
        return self.block_count - self.used_count

    cdef bool can_fit_data(self, unsigned int block_count):
        cdef unsigned int blocks_on_tail = self.get_blocks_on_tail()
        cdef unsigned int largest_free = self.get_largest_free_block()
        if block_count < blocks_on_tail or block_count < largest_free:
            return True
        else:
            return False

    cdef void clear(self):
        '''Clear the whole buffer and mark all blocks as available.
        '''
        self.used_count = 0
        self.free_blocks = []
        self.free_block_count = 0
        self.data_in_free = 0


cdef class MemoryBlock(Buffer):
    
    def __cinit__(self, unsigned int size_in_blocks, 
        unsigned int size_of_blocks, unsigned int type_size):
        self.master_index = 0

    cdef void allocate_memory_with_buffer(self, Buffer master_buffer):
        self.master_buffer = master_buffer
        cdef unsigned int index = master_buffer.add_data(self.size)
        self.master_index = index
        self.data = master_buffer.get_pointer(index)

    cdef void remove_from_buffer(self):
        cdef Buffer master_buffer = self.master_buffer
        master_buffer.remove_data(self.master_index, self.size)
        self.master_index = 0

    cdef void deallocate_memory(self):
        pass

    cdef void* get_pointer(self, unsigned int block_index):
        cdef char* data = <char*>self.data
        return &data[block_index*self.type_size]


cdef class MemoryPool:

    def __cinit__(self, unsigned int block_size_in_kb, Buffer master_buffer,
        unsigned int type_size, unsigned int desired_count):
        self.blocks_with_free_space = []
        self.memory_blocks = mem_blocks = []
        self.used = 0
        self.free_count = 0
        self.type_size = type_size
        cdef unsigned int size_in_bytes = (block_size_in_kb * 1024)
        cdef unsigned int slots_per_block = size_in_bytes // type_size
        cdef unsigned int block_count = (desired_count//slots_per_block) + 1
        self.count = slots_per_block * block_count
        self.slots_per_block = slots_per_block
        self.block_count = block_count
        print('pool has ', block_count, 'taking up', 
            block_size_in_kb*block_count)
        self.master_buffer = master_buffer
        cdef MemoryBlock master_block 
        self.master_block = master_block = MemoryBlock(block_count,
            block_size_in_kb, size_in_bytes)
        master_block.allocate_memory_with_buffer(master_buffer)
        mem_blocks_a = mem_blocks.append
        cdef MemoryBlock mem_block
        for x in range(block_count):
            mem_block = MemoryBlock(1, block_size_in_kb, type_size)
            mem_block.allocate_memory_with_buffer(master_block)
            mem_blocks_a(mem_block)

    cdef unsigned int get_block_from_index(self, unsigned int index):
        return index // self.slots_per_block 

    cdef unsigned int get_slot_index_from_index(self, unsigned int index):
        return index % self.slots_per_block

    cdef MemoryBlock get_memory_block_from_index(self, unsigned int index):
        return self.memory_blocks[self.get_block_from_index(index)]

    cdef unsigned int get_index_from_slot_index_and_block(self, 
        unsigned int slot_index, unsigned int block_index):
        return (block_index * self.slots_per_block) + slot_index

    cdef void* get_pointer(self, unsigned int index):
        cdef MemoryBlock mem_block = self.get_memory_block_from_index(index)
        cdef unsigned int slot_index = self.get_slot_index_from_index(index)
        return mem_block.get_pointer(slot_index)

    cdef unsigned int get_free_slot(self) except -1:
        cdef unsigned int index
        cdef unsigned int block_index
        cdef MemoryBlock mem_block
        cdef list mem_blocks = self.memory_blocks
        cdef list free_blocks = self.blocks_with_free_space
        if self.used == self.count:
            raise MemoryError()
        if self.free_count <= 0:
            block_index = self.get_block_from_index(self.used)
            mem_block = mem_blocks[block_index]
            self.used += 1
            index = mem_block.add_data(1)
        else:
            block_index = free_blocks[0]
            mem_block = mem_blocks[block_index]
            self.free_count -= 1
            index = mem_block.add_data(1)
            if mem_block.free_block_count == 0:
                free_blocks.remove(block_index)
        return self.get_index_from_slot_index_and_block(index, block_index)

    cdef void free_slot(self, unsigned int index):
        cdef unsigned int block_index = self.get_block_from_index(index)
        cdef unsigned int slot_index = self.get_slot_index_from_index(index)
        cdef MemoryBlock mem_block
        cdef list mem_blocks = self.memory_blocks
        cdef list free_blocks = self.blocks_with_free_space
        mem_block = mem_blocks[block_index]
        mem_block.remove_data(slot_index, 1)
        self.free_count += 1
        if self.free_count == self.used:
            self.clear()
        if block_index not in free_blocks:
            free_blocks.append(block_index)

    cdef void clear(self):
        self.blocks_with_free_space = []
        self.used = 0
        self.free_count = 0  

cdef class MemoryZone:

    def __cinit__(self, unsigned int block_size_in_kb, Buffer master_buffer,
        unsigned int type_size, dict desired_counts):
        self.count = 0
        self.block_size_in_kb = block_size_in_kb
        self.reserved_count = 0
        self.master_buffer = master_buffer
        self.memory_pools = memory_pools = {}
        cdef str key
        self.reserved_names = reserved_names = []
        re_a = reserved_names.append
        cdef MemoryPool pool
        cdef unsigned int pool_count
        cdef unsigned int index
        self.reserved_ranges = reserved_ranges = []
        range_a = reserved_ranges.append
        for key in desired_counts:
            re_a(key)
            index = self.count
            memory_pools[self.reserved_count] = pool = MemoryPool(
                block_size_in_kb, master_buffer, type_size, 
                desired_counts[key])
            self.reserved_count += 1
            pool_count = pool.block_count * pool.slots_per_block
            range_a((index, index+pool_count-1))
            self.count += pool_count

    cdef unsigned int get_pool_index_from_name(self, str zone_name):
        return self.reserved_names.index(zone_name)

    cdef unsigned int get_pool_index_from_index(self, unsigned int index):
        cdef list reserved_ranges = self.reserved_ranges
        cdef tuple reserve
        cdef unsigned int reserved_count = self.reserved_count
        cdef unsigned int i, start, end
        for i in range(reserved_count):
            reserve = reserved_ranges[i]
            start = reserve[0]
            end = reserve[1]
            if start <= index <= end:
                return i

    cdef unsigned int remove_pool_offset(self, unsigned int index,
        unsigned int pool_index):
        cdef list reserved_ranges = self.reserved_ranges
        cdef unsigned int start = reserved_ranges[pool_index][0]
        return index - start
        
    cdef unsigned int add_pool_offset(self, unsigned int index,
        unsigned int pool_index):
        cdef list reserved_ranges = self.reserved_ranges
        cdef unsigned int start = reserved_ranges[pool_index][0]
        return index + start

    cdef unsigned int get_pool_offset(self, unsigned int pool_index):
        return self.reserved_ranges[pool_index][0]

    cdef tuple get_pool_range(self, unsigned int pool_index):
        return self.reserved_ranges[pool_index]

    cdef unsigned int get_start_of_pool(self, unsigned int pool_index):
        if pool_index >= self.reserved_count:
            return self.count + 1
        cdef list reserved_ranges = self.reserved_ranges
        cdef unsigned int start = reserved_ranges[pool_index][0]
        return start

    cdef unsigned int get_pool_end_from_pool_index(self, unsigned int index):
        cdef unsigned int used = self.get_pool_from_pool_index(index).used
        return self.add_pool_offset(used, index)

    cdef MemoryPool get_pool_from_pool_index(self, unsigned int pool_index):
        return self.memory_pools[pool_index]

    cdef unsigned int get_block_from_index(self, unsigned int index):
        cdef unsigned int pool_index = self.get_pool_index_from_index(index)
        cdef unsigned int uadjusted_index = self.remove_pool_offset(index,
            pool_index)
        cdef MemoryPool pool = self.get_pool_from_pool_index(pool_index)
        return pool.get_block_from_index(uadjusted_index)

    cdef unsigned int get_slot_index_from_index(self, unsigned int index):
        cdef unsigned int pool_index = self.get_pool_index_from_index(index)
        cdef unsigned int unadjusted_index = self.remove_pool_offset(index,
            pool_index)
        cdef MemoryPool pool = self.get_pool_from_pool_index(pool_index)
        return pool.get_slot_index_from_index(unadjusted_index)

    cdef MemoryBlock get_memory_block_from_index(self, unsigned int index):
        cdef unsigned int pool_index = self.get_pool_index_from_index(index)
        cdef unsigned int unadjusted_index = self.remove_pool_offset(index,
            pool_index)
        cdef MemoryPool pool = self.get_pool_from_pool_index(pool_index)
        return pool.get_memory_block_from_index(unadjusted_index)

    cdef unsigned int get_index_from_slot_block_pool_index(self, 
        unsigned int slot_index, unsigned int block_index, 
        unsigned int pool_index):
        cdef MemoryPool pool = self.get_pool_from_pool_index(pool_index)
        cdef unsigned int unadjusted = (
            pool.get_index_from_slot_index_and_block(slot_index, block_index))
        return self.add_pool_offset(unadjusted, pool_index)

    cdef tuple get_pool_block_slot_indices(self, unsigned int index):
        return (self.get_pool_index_from_index(index), 
            self.get_block_from_index(index), 
            self.get_slot_index_from_index(index))
        
    cdef unsigned int get_free_slot(self, str reserved_hint) except -1:
        cdef unsigned int pool_index = self.reserved_names.index(reserved_hint)
        cdef MemoryPool pool = self.get_pool_from_pool_index(pool_index)
        cdef unsigned int unadjusted_index = pool.get_free_slot()
        return self.add_pool_offset(unadjusted_index, pool_index)

    cdef void free_slot(self, unsigned int index):
        cdef unsigned int pool_index = self.get_pool_index_from_index(index)
        cdef unsigned int unadjusted_index = self.remove_pool_offset(index,
            pool_index)
        cdef MemoryPool pool = self.get_pool_from_pool_index(pool_index)
        pool.free_slot(unadjusted_index)

    cdef void* get_pointer(self, unsigned int index):
        cdef unsigned int pool_index = self.get_pool_index_from_index(index)
        cdef unsigned int unadjusted_index = self.remove_pool_offset(index,
            pool_index)
        cdef MemoryPool pool = self.get_pool_from_pool_index(pool_index)
        return pool.get_pointer(unadjusted_index)


ctypedef struct Test:
    float x
    float y


cdef class TestComponent:
    cdef void* pointer
    cdef unsigned int index

    def __cinit__(self, MemoryBlock memory_block, unsigned int index,
            unsigned int offset):
        self.index = index + offset
        self.pointer = memory_block.get_pointer(index)

    property x:
        def __get__(self):
            cdef Test* pointer = <Test*>self.pointer
            return pointer.x
        def __set__(self, float new_value):
            cdef Test* pointer = <Test*>self.pointer
            pointer.x = new_value

    property y:
        def __get__(self):
            cdef Test* pointer = <Test*>self.pointer
            return pointer.y
        def __set__(self, float new_value):
            cdef Test* pointer = <Test*>self.pointer
            pointer.y = new_value


def test_buffer(size_in_kb):
    master_buffer = Buffer(size_in_kb, 1024, 1)
    master_buffer.allocate_memory()
    
    mem_blocks = []
    for x in range(8):
        mem_blocks.append(test_block(master_buffer, x))

    for x in range(8):
        test_block_read(mem_blocks[x], x)
    cdef MemoryBlock mem_block
    for x in range(2, 6):
        mem_block = mem_blocks[x]
        mem_block.remove_from_buffer()
        mem_blocks[x] = None

    for x in range(2, 6):
        mem_blocks[x] = test_block(master_buffer, x+8)

    for x in range(2, 6):
        test_block_read(mem_blocks[x], x+8)

def test_block_index(size_in_kb, block_size):
    master_buffer = Buffer(size_in_kb, 1024, 1)
    master_buffer.allocate_memory()
    cdef MemoryBlock mem_block = MemoryBlock(1, block_size, sizeof(Test))
    mem_block.allocate_memory_with_buffer(master_buffer)
    block_index = BlockIndex(mem_block, 0, TestComponent)
    block_objects = block_index.blocks
    block_count = mem_block.block_count
    for x in range(block_count):
        block = block_objects[x]
        block.x = block_count - x
        block.y = block_count - x

    for x in range(block_count):
        real_index = block_count - (x+1)
        block = block_objects[real_index]
        assert(block.x==x+1)
        assert(block.y==x+1)


def test_block_read(MemoryBlock mem_block, float block_index):
    cdef Test* mem_test
    for i in range(mem_block.block_count):
        mem_test = <Test*>mem_block.get_pointer(i)
        assert(mem_test.x==block_index)
        assert(mem_test.y==block_index)
    
def test_block(master_buffer, float block_index):
    cdef Test* mem_test
    mem_block_1 = MemoryBlock(1, 16, sizeof(Test))
    mem_block_1.allocate_memory_with_buffer(master_buffer)
    for i in range(mem_block_1.block_count):
        mem_test = <Test*>mem_block_1.get_pointer(i)
        mem_test.x = block_index
        mem_test.y = block_index
    
    return mem_block_1

def test_pool(size_in_kb, size_of_pool):
    master_buffer = Buffer(size_in_kb, 1024, 1)
    master_buffer.allocate_memory()
    cdef MemoryPool memory_pool = MemoryPool(
        size_of_pool, master_buffer, sizeof(Test), 10000)
    cdef Test* test_mem
    cdef Test* read_mem
    cdef unsigned int x
    indices = []
    i_a = indices.append
    for x in range(600):
        index = memory_pool.get_free_slot()
        i_a(index)
        test_mem = <Test*>memory_pool.get_pointer(index)
        test_mem.x = float(index)
        test_mem.y = float(index)
        #print(test_mem.x, test_mem.y)

    for x in range(350):
        memory_pool.free_slot(x)

    for x in range(350):
        index = memory_pool.get_free_slot()
        test_mem = <Test*>memory_pool.get_pointer(index)
        test_mem.x = float(index)
        test_mem.y = float(index)


    for index in indices:
        read_mem = <Test*>memory_pool.get_pointer(index)
        assert(read_mem.x==index)
        assert(read_mem.y==index)


def test_zone(size_in_kb, pool_block_size, general_count, test_count):
    reserved_spec = {
        'general': 5000,
        'test': 1000,
    }
    master_buffer = Buffer(size_in_kb, 1024, 1)
    master_buffer.allocate_memory()
    cdef MemoryZone memory_zone = MemoryZone(pool_block_size, master_buffer,
        sizeof(Test), reserved_spec)

    cdef int index
    cdef list indices = []
    i_a = indices.append
    cdef Test* test_mem
    cdef int i
    for x in range(general_count):
        index = memory_zone.get_free_slot('general')
        i_a(index)
        test_mem = <Test*>memory_zone.get_pointer(index)
        test_mem.x = float(index)
        test_mem.y = float(index)

    for x in range(test_count):
        index = memory_zone.get_free_slot('test')
        i_a(index)
        test_mem = <Test*>memory_zone.get_pointer(index)
        test_mem.x = float(index)
        test_mem.y = float(index)

    for i in indices:
        test_mem = <Test*>memory_zone.get_pointer(i)
        assert(test_mem.x==float(i))
        assert(test_mem.y==float(i))


def test_zone_index(size_in_kb, pool_block_size, general_count, test_count):
    reserved_spec = {
        'general': 5000,
        'test': 1000,
    }
    master_buffer = Buffer(size_in_kb, 1024, 1)
    master_buffer.allocate_memory()
    cdef MemoryZone memory_zone = MemoryZone(pool_block_size, master_buffer,
        sizeof(Test), reserved_spec)
    cdef ZoneIndex zone_index = ZoneIndex(memory_zone, TestComponent)
    cdef int index
    cdef list indices = []
    i_a = indices.append
    cdef TestComponent test_mem
    cdef int i
    for x in range(general_count):
        index = memory_zone.get_free_slot('general')
        i_a(index)
        test_mem = zone_index.get_component_from_index(index)
        test_mem.x = float(index)
        test_mem.y = float(index)

    for x in range(test_count):
        index = memory_zone.get_free_slot('test')
        i_a(index)
        test_mem = zone_index.get_component_from_index(index)
        test_mem.x = float(index)
        test_mem.y = float(index)

    for i in indices:
        test_mem = zone_index.get_component_from_index(i)
        assert(test_mem.x==float(i))
        assert(test_mem.y==float(i))

def test_indexed_memory_zone(size_in_kb, pool_block_size, 
    general_count, test_count):
    reserved_spec = {
        'general': 200,
        'test': 200,
    }
    master_buffer = Buffer(size_in_kb, 1024, 1)
    master_buffer.allocate_memory()
    cdef IndexedMemoryZone memory_index = IndexedMemoryZone(master_buffer, 
        pool_block_size, sizeof(int)*8, reserved_spec, MemComponent)
    cdef IndexedMemoryZone memory_index_2 = IndexedMemoryZone(master_buffer, 
        pool_block_size, sizeof(Test), {'general': 200}, MemComponent)
    cdef unsigned int index
    cdef list indices = []
    i_a = indices.append
    cdef MemComponent entity
    cdef MemoryZone memory_zone = memory_index.memory_zone
    cdef MemoryZone memory_zone_2 = memory_index_2.memory_zone
    cdef int x
    cdef int* pointer
    cdef int i
    for x in range(general_count):
        index = memory_zone.get_free_slot('test')
        i_a(index)
        pointer = <int*>memory_zone.get_pointer(index)
        for i in range(8):
            print(pointer[i])
        entity = memory_index[index]
        print(entity._id, index, 'in creation')

    for x in range(test_count):
        index = memory_zone.get_free_slot('general')
        i_a(index)
        index2 = memory_zone_2.get_free_slot('general')
        entity = memory_index[index]
        print(entity._id, index, 'in creation')
        entity = memory_index_2[index2]
        print(entity._id, index, 'in creation 2')
        
    for entity in memrange(memory_index):
        print entity._id

    for entity in memrange(memory_index, zone='test'):
        print entity._id


