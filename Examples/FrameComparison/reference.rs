// Benchmark reference only; this Rust core is not part of a Swift package product.
#![no_std]
#![no_main]

use core::{marker::PhantomData, panic::PanicInfo};

#[cfg(not(all(
    target_pointer_width = "64",
    any(target_arch = "aarch64", target_arch = "x86_64"),
    any(target_os = "macos", target_os = "linux")
)))]
compile_error!(
    "This standalone native ABI fixture supports only 64-bit macOS/Linux x86-64/AArch64."
);

#[derive(Debug)]
enum Failure {
    InvalidSize,
    InvalidAlignment,
    Capacity,
    Generation,
}

struct Ticket<'a> {
    first: usize,
    count: usize,
    identity: usize,
    generation: u64,
    offset: usize,
    loan: PhantomData<&'a [u64]>,
}

struct Ledger<'a> {
    metadata: &'a mut [u64],
    identity: usize,
    base: usize,
    #[cfg(cached)]
    free: usize,
}

impl<'a> Ledger<'a> {
    fn new(metadata: &'a mut [u64], base: usize) -> Option<Self> {
        if metadata.len() <= 1
            || base.checked_add(metadata.len() - 1).is_none()
            || metadata[1..].iter().any(|word| *word != 0)
        {
            return None;
        }
        Some(Self {
            identity: metadata.as_ptr() as usize,
            base,
            #[cfg(cached)]
            free: metadata.len() - 1,
            metadata,
        })
    }
    fn capacity(&self) -> usize {
        self.metadata.len() - 1
    }
    fn available(&self) -> usize {
        #[cfg(cached)]
        {
            self.free
        }
        #[cfg(not(cached))]
        {
            self.metadata[1..].iter().filter(|word| **word == 0).count()
        }
    }
    fn reserve(&mut self, count: usize, alignment: usize) -> Result<Ticket<'a>, Failure> {
        if count == 0 {
            return Err(Failure::InvalidSize);
        }
        if alignment == 0 || !alignment.is_power_of_two() {
            return Err(Failure::InvalidAlignment);
        }
        if count > self.capacity() {
            return Err(Failure::Capacity);
        }
        if self.metadata[0] == u64::MAX {
            return Err(Failure::Generation);
        }
        #[cfg(cached)]
        if count > self.free {
            return Err(Failure::Capacity);
        }
        let mut offset = 0;
        while offset <= self.capacity() - count {
            let padding = 0usize.wrapping_sub(self.base + offset) & (alignment - 1);
            if padding > self.capacity() - count - offset {
                break;
            }
            offset += padding;
            let mut prefix = 0;
            while prefix < count && self.metadata[offset + prefix + 1] == 0 {
                prefix += 1;
            }
            if prefix == count {
                let generation = self.metadata[0] + 1;
                self.metadata[0] = generation;
                for slot in &mut self.metadata[(offset + 1)..(offset + count + 1)] {
                    *slot = generation;
                }
                #[cfg(cached)]
                {
                    self.free -= count;
                }
                return Ok(Ticket {
                    first: self.base + offset,
                    count,
                    identity: self.identity,
                    generation,
                    offset,
                    loan: PhantomData,
                });
            }
            offset += prefix + 1;
        }
        Err(Failure::Capacity)
    }
    fn release(&mut self, ticket: Ticket<'a>) -> Result<(), Ticket<'a>> {
        #[cfg(cached)]
        if ticket.generation == 0 {
            return Err(ticket);
        }
        if ticket.identity != self.identity
            || ticket.count == 0
            || ticket.count > self.capacity()
            || ticket.offset > self.capacity() - ticket.count
            || ticket.first != self.base + ticket.offset
        {
            return Err(ticket);
        }
        if self.metadata[(ticket.offset + 1)..(ticket.offset + ticket.count + 1)]
            .iter()
            .any(|slot| *slot != ticket.generation)
        {
            return Err(ticket);
        }
        #[cfg(cached)]
        assert!(self.free <= self.capacity() - ticket.count);
        for slot in &mut self.metadata[(ticket.offset + 1)..(ticket.offset + ticket.count + 1)] {
            *slot = 0;
        }
        #[cfg(cached)]
        {
            self.free += ticket.count;
        }
        Ok(())
    }
}

// Native Darwin declarations match the pinned SDK's mach/mach_time.h; no C implementation.
#[repr(C)]
struct Timebase {
    numer: u32,
    denom: u32,
}
#[repr(C)]
#[cfg(target_os = "linux")]
struct Timespec {
    seconds: i64,
    nanoseconds: i64,
}
#[cfg_attr(target_os = "macos", link(name = "System"))]
#[cfg_attr(target_os = "linux", link(name = "c"))]
unsafe extern "C" {
    #[cfg(target_os = "macos")]
    fn mach_absolute_time() -> u64;
    #[cfg(target_os = "macos")]
    fn mach_timebase_info(info: *mut Timebase) -> i32;
    #[cfg(target_os = "linux")]
    fn clock_gettime(clock: i32, time: *mut Timespec) -> i32;
    fn putchar(value: i32) -> i32;
    fn abort() -> !;
}

#[inline(always)]
fn current_ticks() -> u64 {
    #[cfg(target_os = "macos")]
    {
        // SAFETY: the native monotonic clock has no pointer or state precondition.
        unsafe { mach_absolute_time() }
    }
    #[cfg(target_os = "linux")]
    {
        let mut time = Timespec {
            seconds: 0,
            nanoseconds: 0,
        };
        // SAFETY: Linux x86-64/AArch64 timespec is two signed 64-bit words, alive and writable.
        assert_eq!(unsafe { clock_gettime(4, &mut time) }, 0);
        assert!(time.seconds >= 0 && time.nanoseconds >= 0 && time.nanoseconds < 1_000_000_000);
        time.seconds as u64 * 1_000_000_000 + time.nanoseconds as u64
    }
}

#[panic_handler]
fn panic(_: &PanicInfo<'_>) -> ! {
    // SAFETY: abort is the process-terminal platform contract; no unwind or cleanup is claimed.
    unsafe { abort() }
}

// Prebuilt Linux core retains this ABI reference even with panic=abort; never pretend to unwind.
#[cfg(target_os = "linux")]
#[no_mangle]
extern "C" fn rust_eh_personality(
    _version: i32,
    _actions: i32,
    _exception_class: u64,
    _exception: *mut core::ffi::c_void,
    _context: *mut core::ffi::c_void,
) -> i32 {
    // SAFETY: the native terminal call dereferences no argument and never returns to an unwinder.
    unsafe { abort() }
}

#[inline(never)]
fn churn_step(ledger: &mut Ledger<'_>, iteration: usize, request: &u64) -> u64 {
    // SAFETY: this initialized aligned scalar is borrowed for the whole call, without concurrent writes.
    let input = unsafe { core::ptr::read_volatile(request) };
    assert_eq!(input, 1);
    let first_count = 1 + (iteration + input as usize) % 7;
    let second_count = 1 + (iteration + input as usize) % 3;
    let first = ledger.reserve(first_count, 8).expect("First reservation");
    let second = ledger.reserve(second_count, 2).expect("Second reservation");
    let first_frame = first.first;
    let second_frame = second.first;
    assert_eq!(first_frame, 8);
    assert_eq!(second_frame, 4);
    assert_eq!(
        ledger.available(),
        ledger.capacity() - first_count - second_count
    );
    assert!(ledger.release(second).is_ok());
    let replacement = ledger.reserve(second_count, 2).expect("Replacement");
    assert_eq!(replacement.first, second_frame);
    assert!(ledger.release(first).is_ok());
    assert!(ledger.release(replacement).is_ok());
    assert_eq!(ledger.available(), ledger.capacity());
    (first_frame + second_frame + iteration) as u64
}

#[inline(never)]
fn refusal_step(
    ledger: &mut Ledger<'_>,
    iteration: usize,
    request: &u64,
    expected_free: usize,
) -> u64 {
    // SAFETY: same owner-bound initialized scalar as churn_step; single execution context.
    let input = unsafe { core::ptr::read_volatile(request) };
    assert!(matches!(
        ledger.reserve(input as usize, 1),
        Err(Failure::Capacity)
    ));
    let free = ledger.available();
    assert_eq!(free, expected_free);
    (free + iteration) as u64
}

fn emit(mut value: u64) {
    let mut digits = [0u8; 20];
    let mut count = 0;
    loop {
        digits[count] = (value % 10) as u8 + 48;
        value /= 10;
        count += 1;
        if value == 0 {
            break;
        }
    }
    for index in (0..count).rev() {
        // SAFETY: putchar accepts a promoted unsigned byte; output is outside the timed region.
        unsafe {
            putchar(digits[index] as i32);
        }
    }
    // SAFETY: newline is a valid promoted character.
    unsafe {
        putchar(10);
    }
}

fn measure(
    ledger: &mut Ledger<'_>,
    ticks: &mut [u64; 32],
    iterations: usize,
    mode: usize,
    request: &u64,
    expected_free: usize,
) -> u64 {
    let mut checksum = 0;
    for batch in 0..34 {
        let begin = current_ticks();
        let mut digest = 0;
        for iteration in 0..iterations {
            digest += if mode == 0 {
                churn_step(ledger, iteration, request)
            } else {
                refusal_step(ledger, iteration, request, expected_free)
            };
        }
        let elapsed = current_ticks() - begin;
        let expected = iterations * (iterations - 1) / 2
            + iterations * if mode == 0 { 12 } else { expected_free };
        assert_eq!(digest, expected as u64);
        if batch >= 2 {
            ticks[batch - 2] = elapsed;
            checksum += digest;
        }
    }
    checksum
}

#[no_mangle]
extern "C" fn main() -> i32 {
    let mut metadata = [0u64; 65537];
    #[cfg(target_os = "macos")]
    let info = {
        let mut info = Timebase { numer: 0, denom: 0 };
        // SAFETY: writable, correctly aligned native two-u32 record lives throughout this call.
        assert_eq!(unsafe { mach_timebase_info(&mut info) }, 0);
        info
    };
    #[cfg(target_os = "linux")]
    let info = Timebase { numer: 1, denom: 1 };
    assert_ne!(info.denom, 0);
    let mut clock_pairs = [0u64; 32];
    for ticks in &mut clock_pairs {
        let begin = current_ticks();
        *ticks = current_ticks() - begin;
    }
    emit(2);
    emit(info.numer as u64);
    emit(info.denom as u64);
    emit(core::mem::size_of_val(&metadata) as u64);
    emit((metadata.as_ptr() as usize & 63) as u64);
    for ticks in clock_pairs {
        emit(ticks);
    }
    for capacity in [128, 1024, 4096, 16384, 65536] {
        for mode in 0..3 {
            metadata[0] = 0;
            let mut ticks = [0u64; 32];
            let iterations = if mode == 0 {
                256
            } else if mode == 1 {
                32
            } else {
                16
            };
            let request = if mode == 2 { capacity as u64 / 2 } else { 1 };
            let checksum;
            {
                let mut ledger =
                    Ledger::new(&mut metadata[..(capacity + 1)], 3).expect("Fresh metadata");
                if mode == 0 {
                    checksum = measure(
                        &mut ledger,
                        &mut ticks,
                        iterations,
                        mode,
                        &request,
                        capacity,
                    );
                } else if mode == 1 {
                    let full = ledger.reserve(capacity, 1).expect("Full setup");
                    checksum = measure(&mut ledger, &mut ticks, iterations, mode, &request, 0);
                    assert!(ledger.release(full).is_ok());
                } else {
                    let quarter = capacity / 4;
                    let first = ledger.reserve(quarter, 1).expect("First quarter");
                    let second = ledger.reserve(quarter, 1).expect("Second quarter");
                    let third = ledger.reserve(quarter, 1).expect("Third quarter");
                    let fourth = ledger.reserve(quarter, 1).expect("Fourth quarter");
                    assert!(ledger.release(first).is_ok());
                    assert!(ledger.release(third).is_ok());
                    checksum = measure(
                        &mut ledger,
                        &mut ticks,
                        iterations,
                        mode,
                        &request,
                        capacity / 2,
                    );
                    assert!(ledger.release(second).is_ok());
                    assert!(ledger.release(fourth).is_ok());
                }
                assert_eq!(ledger.available(), capacity);
            }
            let generation = if mode == 0 {
                34 * iterations * 3
            } else if mode == 1 {
                1
            } else {
                4
            };
            assert_eq!(metadata[0], generation as u64);
            assert!(metadata[1..].iter().all(|word| *word == 0));
            let raw_ticks = ticks;
            for index in 1..32 {
                let mut current = index;
                while current > 0 && ticks[current] < ticks[current - 1] {
                    ticks.swap(current, current - 1);
                    current -= 1;
                }
            }
            emit(capacity as u64);
            emit(mode as u64);
            emit(iterations as u64);
            for index in [15, 30, 31] {
                emit(ticks[index] * info.numer as u64 / info.denom as u64 / iterations as u64);
            }
            emit(checksum);
            emit(generation as u64);
            for ticks in raw_ticks {
                emit(ticks);
            }
        }
    }
    0
}
