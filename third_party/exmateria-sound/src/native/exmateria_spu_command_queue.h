#ifndef EXMATERIA_SPU_COMMAND_QUEUE_H
#define EXMATERIA_SPU_COMMAND_QUEUE_H

#include <atomic>
#include <cstdint>
#include <vector>

// Timestamped SPU register-write queue — D3 decision 3 (#376).
//
// The FFT sound driver stays in GDScript: it decides which SPU registers to
// write and when. What changes is WHERE the write lands. In lockstep mode the
// GDScript sequencer wrote the register and then rendered the tick's samples
// itself; here it writes the register into this queue stamped with the frame
// the write belongs at, and the audio thread applies it at exactly that frame
// on its way through ExMateriaSpuPlayback::_mix_resampled.
//
// Concurrency contract — single producer, single consumer, wait-free:
//   * producer = whichever thread drives the sequencer (SMDPlayer schedules
//     from the main thread's _process; there is no producer thread any more).
//   * consumer = the audio thread, inside _mix.
//   * `head_` is written only by the producer, `tail_` only by the consumer.
//     The release/acquire pair on those two indices is the entire handshake;
//     the command payload itself is plain memory, published by the release
//     store on `head_` and read after the acquire load of it.
// No lock is taken on either side, so a producer stall cannot block the audio
// thread — it can only starve it of new register writes, which sounds like the
// music holding its last note rather than a dropout.
//
// The queue is bounded and NEVER blocks the producer. A push into a full ring
// is dropped and counted (`overflow_count`), because dropping a register write
// is a bug the caller must size its way out of (see free_slots(), which the
// scheduler consults before it runs further ahead) — not something to hide by
// stalling the game thread.

namespace exmateria {

// One deferred SPU register write. 64 bytes exactly, so the ring is a flat
// array of cache-line-friendly PODs with no indirection and no allocation on
// either thread after set_capacity().
enum class SpuCommandOp : int32_t {
	KEY_ON = 0,
	KEY_ON_WITH_ADDRESSES,
	KEY_OFF,
	SET_VOICE_PITCH,
	SET_VOICE_FMOD,
	SET_VOICE_NOISE,
	SET_NOISE_CLOCK,
	SET_VOICE_PRE_PITCH,
	SET_VOICE_ADSR1_LOW,
	SET_VOICE_ADSR2,
	SET_VOICE_VOLUME_LR,
	SET_VOICE_VOLUME_LR_WITH_MODE,
	SET_VOICE_ADSR1_HIGH,
	SET_VOICE_ADSR1_MID,
	SET_VOICE_ADSR2_LOW,
	SET_VOICE_START_ADDR,
	SET_VOICE_REPEAT_ADDR,
	INIT_VOICE_PITCH_LFO,
	CLEAR_VOICE_PITCH_LFO,
	SET_VOICE_PITCH_LFO_DEPTH,
	INIT_VOICE_VOLUME_LFO,
	CLEAR_VOICE_VOLUME_LFO,
	SET_VOICE_VOLUME_LFO_DEPTH,
	SET_REVERB_ENABLED,
	SET_LFO_TICK_SAMPLES,
	SET_LFO_PITCH_BIAS_ENABLED,
	CARRY_VOICE_DECLICK,
};

static constexpr int kSpuCommandMaxArgs = 12;

struct SpuCommand {
	// Absolute frame (SPU sample index since the stream started) this write
	// belongs at. The consumer renders up to this frame, then applies.
	uint64_t at_frame = 0;
	SpuCommandOp op = SpuCommandOp::KEY_OFF;
	int32_t argc = 0;
	int32_t args[kSpuCommandMaxArgs] = {};
};

static_assert(sizeof(SpuCommand) == 64, "SpuCommand must stay one 64-byte slot");

class SpuCommandQueue {
public:
	// Capacity is rounded up to a power of two (the ring masks rather than
	// divides). Call from the owning thread while no playback is running —
	// this is the only allocation in the queue's life.
	void set_capacity(int p_capacity) {
		int cap = 64;
		while (cap < p_capacity) {
			cap <<= 1;
		}
		ring_.assign(static_cast<size_t>(cap), SpuCommand{});
		mask_ = static_cast<uint32_t>(cap - 1);
		clear();
	}

	// Drop every pending command and zero the counters. Safe only when the
	// consumer is stopped (song switch, stream stop).
	void clear() {
		head_.store(0, std::memory_order_relaxed);
		tail_.store(0, std::memory_order_relaxed);
		overflow_count_ = 0;
		high_water_ = 0;
	}

	int capacity() const { return ring_.empty() ? 0 : static_cast<int>(mask_) + 1; }

	// Producer side ------------------------------------------------------

	bool push(const SpuCommand &p_cmd) {
		if (ring_.empty()) {
			return false;
		}
		const uint32_t head = head_.load(std::memory_order_relaxed);
		const uint32_t next = (head + 1) & mask_;
		if (next == tail_.load(std::memory_order_acquire)) {
			++overflow_count_;
			return false;
		}
		ring_[head] = p_cmd;
		head_.store(next, std::memory_order_release);
		const int pending = pending_count();
		if (pending > high_water_) {
			high_water_ = pending;
		}
		return true;
	}

	// How many more commands fit right now. The scheduler stops running ahead
	// when this gets low, which is what keeps overflow_count at zero.
	int free_slots() const {
		if (ring_.empty()) {
			return 0;
		}
		return static_cast<int>(mask_) - pending_count();
	}

	int pending_count() const {
		const uint32_t head = head_.load(std::memory_order_relaxed);
		const uint32_t tail = tail_.load(std::memory_order_relaxed);
		return static_cast<int>((head - tail) & mask_);
	}

	// Zero the diagnostic counters WITHOUT disturbing the ring — a monitoring
	// window reset, unlike clear(), which also drops pending writes.
	void reset_stats() {
		overflow_count_ = 0;
		high_water_ = 0;
	}
	uint64_t overflow_count() const { return overflow_count_; }
	int high_water() const { return high_water_; }

	// Consumer side ------------------------------------------------------

	// The next command due, or nullptr when the queue is empty. The pointer
	// stays valid until pop_front().
	const SpuCommand *peek() const {
		if (ring_.empty()) {
			return nullptr;
		}
		const uint32_t tail = tail_.load(std::memory_order_relaxed);
		if (tail == head_.load(std::memory_order_acquire)) {
			return nullptr;
		}
		return &ring_[tail];
	}

	void pop_front() {
		const uint32_t tail = tail_.load(std::memory_order_relaxed);
		tail_.store((tail + 1) & mask_, std::memory_order_release);
	}

private:
	std::vector<SpuCommand> ring_;
	uint32_t mask_ = 0;
	std::atomic<uint32_t> head_{ 0 };
	std::atomic<uint32_t> tail_{ 0 };
	// Diagnostics. Written by the producer only; read for the debug readout,
	// where a torn read costs nothing.
	uint64_t overflow_count_ = 0;
	int high_water_ = 0;
};

} // namespace exmateria

#endif
