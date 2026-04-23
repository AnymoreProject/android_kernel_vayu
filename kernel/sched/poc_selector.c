// SPDX-License-Identifier: GPL-2.0
/*
 * Piece-Of-Cake (POC) CPU Selector
 * Backported for Linux 4.14
 */

#ifdef CONFIG_SCHED_POC_SELECTOR

/**************************************************************
 * Version Information:
 */

#define SCHED_POC_SELECTOR_AUTHOR   "Masahito Suzuki"
#define SCHED_POC_SELECTOR_PROGNAME "Piece-Of-Cake (POC) CPU Selector"
#define SCHED_POC_SELECTOR_VERSION  "2.5.7-v4.14-backport"

/**************************************************************
 * Static keys:
 */

DEFINE_STATIC_KEY_TRUE(poc_selector_active);
static bool sched_poc_selector = true;

DEFINE_STATIC_KEY_FALSE(sched_poc_smt_fallback);
DEFINE_STATIC_KEY_TRUE(sched_poc_eager_commit);
DEFINE_STATIC_KEY_TRUE(sched_poc_smt_consecutive);
DEFINE_STATIC_KEY_TRUE(sched_poc_smt_uniform);
DEFINE_STATIC_KEY_FALSE(sched_poc_target_sticky);
DEFINE_STATIC_KEY_TRUE(sched_poc_early_select);
DEFINE_STATIC_KEY_TRUE(sched_poc_greedy_search);
DEFINE_STATIC_KEY_TRUE(sched_poc_aligned);
DEFINE_STATIC_KEY_TRUE(sched_poc_packed);
DEFINE_STATIC_KEY_FALSE(sched_poc_lockless_bitmap);

enum poc_level {
	POC_LV1S = 0,
	POC_LV1T,
	POC_LV1P,
	POC_LV1R,
	POC_LV2,
	POC_LV3,
	POC_LV4S,
	POC_LV4P,
	POC_LV4R,
	POC_LV4T,
	POC_LV5,
	POC_LV6,
	POC_FALLBACK,
	POC_NR_LEVELS
};

#define POC_SMT_LEVEL_OFFSET (POC_LV5 - POC_LV2)

DEFINE_STATIC_KEY_FALSE(sched_poc_count_enabled);
static DEFINE_PER_CPU(unsigned long[POC_NR_LEVELS], poc_debug_cnt);

static __always_inline void poc_count(enum poc_level lv)
{
	if (static_branch_unlikely(&sched_poc_count_enabled))
		__this_cpu_inc(poc_debug_cnt[lv]);
}

/**************************************************************
 * Per-CPU round-robin counter and division-free mapping:
 */

static DEFINE_PER_CPU(u32, poc_rr_counter);

#define POC_FIXED_MOD16(phase, range) ((u32)(((u32)(phase) * (u32)(range)) >> 16))

static const u16 poc_rr_step[64] = {
	     0, 0x8000, 0x5556, 0x4000,	0x3334, 0x2AAB, 0x2493, 0x2000,
	0x1C72, 0x199A, 0x1746, 0x1556,	0x13B2, 0x124A, 0x1112, 0x1000,
	0x0F10, 0x0E39, 0x0D7A, 0x0CCD,	0x0C31, 0x0BA3, 0x0B22, 0x0AAB,
	0x0A3E, 0x09D9, 0x097C, 0x0925,	0x08D4, 0x0889, 0x0843, 0x0800,
	0x07C2, 0x0788, 0x0751, 0x071D,	0x06EC, 0x06BD, 0x0691, 0x0667,
	0x063F, 0x0619, 0x05F5, 0x05D2,	0x05B1, 0x0591, 0x0573, 0x0556,
	0x053A, 0x051F, 0x0506, 0x04ED,	0x04D5, 0x04BE, 0x04A8, 0x0493,
	0x047E, 0x046A, 0x0457, 0x0445,	0x0433, 0x0422, 0x0411, 0x0400,
};

/**************************************************************
 * Bit manipulation primitives:
 */

#if defined(__x86_64__) && defined(__BMI__)
#define POC_CTZ64_NAME "HW (TZCNT)"
#elif defined(__aarch64__)
#define POC_CTZ64_NAME "HW (RBIT+CLZ)"
#elif defined(__riscv) && defined(__riscv_zbb)
#define POC_CTZ64_NAME "HW (ctz)"
#elif defined(__x86_64__)
#define POC_CTZ64_NAME "HW (BSF)"
#else
#define POC_CTZ64_NAME "SW (De Bruijn)"
#endif

#if defined(__x86_64__) && defined(__BMI2__) && \
    !defined(__znver1) && !defined(__znver2)
static __always_inline int poc_ptselect(u64 v, int j)
{
	u64 deposited;
	asm("pdep %2, %1, %0" : "=r"(deposited) : "r"(1ULL << j), "rm"(v));
	return POC_CTZ64(deposited);
}
#define POC_PTSELECT(v, j) poc_ptselect(v, j)
#define POC_PTSELECT_NAME "HW (PDEP)"
#else
static __always_inline int poc_ptselect_sw(u64 v, int j)
{
	int k;
	for (k = 0; k < j; k++)
		v &= v - 1;
	return POC_CTZ64(v);
}
#define POC_PTSELECT(v, j) poc_ptselect_sw(v, j)
#define POC_PTSELECT_NAME "SW (loop)"
#endif

#define POC_BYTE_EXTRACT 0x0101010101010101ULL
#define POC_BYTE_PACK    0x0102040810204080ULL

#if defined(__x86_64__) && defined(__BMI2__) && \
    !defined(__znver1) && !defined(__znver2)
static __always_inline u64 poc_bmp8_pext(u64 word, int i)
{
	u64 extracted;
	asm("pext %2, %1, %0" : "=r"(extracted) : "r"(word), "r"(POC_BYTE_EXTRACT));
	return extracted << (i * 8);
}
#define POC_BMP8(w, i) poc_bmp8_pext((w)[i], i)
#else
#define POC_BMP8(w, i) \
	((((w)[i] & POC_BYTE_EXTRACT) * POC_BYTE_PACK >> 56) << ((i) * 8))
#endif

static __always_inline u64 poc_flags_to_u64(const u8 *flags)
{
	u64 w[8];
	memcpy(w, flags, 64);
	return POC_BMP8(w, 0) | POC_BMP8(w, 1) | POC_BMP8(w, 2) | POC_BMP8(w, 3) |
	       POC_BMP8(w, 4) | POC_BMP8(w, 5) | POC_BMP8(w, 6) | POC_BMP8(w, 7);
}

/**************************************************************
 * Idle mask accessors:
 */

static __always_inline u64 poc_idle_cpu_mask(u64 affinity,
	struct sched_domain_shared *sd_share)
{
	u64 cpus;
	if (static_branch_unlikely(&sched_poc_lockless_bitmap))
		cpus = poc_flags_to_u64(sd_share->poc_idle_cpus);
	else
		cpus = (u64)atomic64_read(&sd_share->poc_idle_cpus_mask);
	return cpus & sd_share->poc_llc_members & affinity;
}

#ifdef CONFIG_SCHED_SMT
static __always_inline u64 poc_idle_core_mask(u64 cpu_mask,
	struct sched_domain_shared *sd_share)
{
	if (static_branch_likely(&sched_poc_smt_consecutive))
		return cpu_mask & (cpu_mask >> 1) & 0x5555555555555555ULL;

	if (static_branch_likely(&sched_poc_smt_uniform))
		return cpu_mask & (cpu_mask >> sd_share->poc_smt_shift)
				& sd_share->poc_primary_mask;

	if (static_branch_unlikely(&sched_poc_lockless_bitmap))
		return poc_flags_to_u64(sd_share->poc_idle_cores) & cpu_mask;

	return (u64)atomic64_read(&sd_share->poc_idle_cores_mask) & cpu_mask;
}
#endif /* CONFIG_SCHED_SMT */

void __set_cpu_idle_state_poc(int cpu, int state)
{
	struct rq *rq = cpu_rq(cpu);
	struct sched_domain_shared *sd_share;
	int bit;
	u64 bit_mask;

	if (!static_branch_unlikely(&sched_poc_lockless_bitmap) &&
			!state && READ_ONCE(rq->poc_idle_committed))
		return;

	/* 4.14 manual RCU locking */
	rcu_read_lock();
	sd_share = rcu_dereference(per_cpu(sd_llc_shared, cpu));
	if (!sd_share || !sd_share->poc_fast_eligible) {
		rcu_read_unlock();
		return;
	}

	bit = cpu - sd_share->poc_cpu_base;
	bit_mask = 1ULL << bit;

	if (static_branch_unlikely(&sched_poc_lockless_bitmap)) {
		WRITE_ONCE(sd_share->poc_idle_cpus[bit], state > 0 ? 1 : 0);
	} else if (state > 0) {
		WRITE_ONCE(rq->poc_idle_committed, 0);
		atomic64_or(bit_mask, &sd_share->poc_idle_cpus_mask);
	} else {
		atomic64_andnot(bit_mask, &sd_share->poc_idle_cpus_mask);
		WRITE_ONCE(rq->poc_idle_committed, 1);
	}

#ifdef CONFIG_SCHED_SMT
	if (sched_smt_active()) {
		if (static_branch_likely(&sched_poc_smt_uniform)) {
			rcu_read_unlock();
			return;
		}

		u64 smt = sd_share->poc_smt_mask[bit];
		u64 core_bitmask = smt & (-smt);
		int core_bit = __builtin_ctzll(core_bitmask);
		bool core_idle;

		if (static_branch_unlikely(&sched_poc_lockless_bitmap)) {
			smp_wmb();
			u64 tmp = smt;

			core_idle = state > 0;
			while (core_idle && tmp) {
				int s = __builtin_ctzll(tmp);
				if (!READ_ONCE(sd_share->poc_idle_cpus[s]))
					core_idle = false;
				tmp &= tmp - 1;
			}
			WRITE_ONCE(sd_share->poc_idle_cores[core_bit],
				   core_idle ? 1 : 0);
		} else {
			smp_mb__after_atomic();
			u64 cpus = (u64)atomic64_read(&sd_share->poc_idle_cpus_mask);
			core_idle = (cpus & smt) == smt;
			u64 cores = (u64)atomic64_read(&sd_share->poc_idle_cores_mask);

			if (core_idle) {
				if (!(cores & core_bitmask))
					atomic64_or(core_bitmask,
						    &sd_share->poc_idle_cores_mask);
			} else {
				if (cores & core_bitmask)
					atomic64_andnot(core_bitmask,
							&sd_share->poc_idle_cores_mask);
			}
		}
	}
#endif /* CONFIG_SCHED_SMT */

	rcu_read_unlock();
}

/**************************************************************
 * Idle CPU selection helpers:
 */

#define POC_IDLE_CPU(bit)	(cpu_mask & (1ULL << (bit)))
#define POC_CPU_VALID(cpu)	((cpu) >= 0)
#define POC_CPU_IN_LLC(bit)	((unsigned int)(bit) < 64)

static __always_inline int poc_select_rr(int base, u64 mask, unsigned int counter)
{
	int total = hweight64(mask);
	u16 phase = (u16)(counter * (u32)poc_rr_step[total - 1]);
	int pick  = POC_FIXED_MOD16(phase, total);
	return POC_PTSELECT(mask, pick) + base;
}

static __always_inline int poc_cluster_search(int base, int tgt_bit,
	struct sched_domain_shared *sd_share, u64 mask)
{
	u64 cls_idle = mask & sd_share->poc_cluster_mask[tgt_bit];
	if (cls_idle)
		return base + POC_CTZ64(cls_idle);
	return -1;
}

#ifdef CONFIG_SCHED_SMT
static __always_inline u64 poc_smt_sibling_mask(int bit,
	struct sched_domain_shared *sd_share)
{
	if (static_branch_likely(&sched_poc_smt_consecutive))
		return 3ULL << (bit & ~1);

	if (static_branch_likely(&sched_poc_smt_uniform)) {
		u8 shift = sd_share->poc_smt_shift;
		int sib = (sd_share->poc_primary_mask & (1ULL << bit))
				? bit + shift : bit - shift;
		return (1ULL << bit) | (1ULL << sib);
	}

	return sd_share->poc_smt_mask[bit];
}

static __always_inline int poc_find_idle_smt_sibling(
	int base, int tgt_bit, u64 cpu_mask, u64 smt_mask)
{
	if (POC_IDLE_CPU(tgt_bit))
		return base + tgt_bit;
	u64 idle_sibs = cpu_mask & smt_mask;
	if (idle_sibs)
		return base + POC_CTZ64(idle_sibs);
	return -1;
}

static __always_inline int poc_try_idle_smt(int base, int cpu,
	u64 cpu_mask, struct sched_domain_shared *sd_share)
{
	int bit = cpu - base;
	if (sd_share->poc_llc_members & (1ULL << bit)) {
		int smt_cpu = poc_find_idle_smt_sibling(base, bit,
			cpu_mask, poc_smt_sibling_mask(bit, sd_share));
		if (POC_CPU_VALID(smt_cpu))
			return smt_cpu;
	}
	return -1;
}
#endif /* CONFIG_SCHED_SMT */

static __always_inline void poc_commit_selection(int cpu,
	struct sched_domain_shared *sd_share)
{
	if (static_branch_likely(&sched_poc_eager_commit) &&
			cpu_rq(cpu)->nr_running <= 2) {
		int bit = cpu - sd_share->poc_cpu_base;

		if (static_branch_unlikely(&sched_poc_lockless_bitmap)) {
			WRITE_ONCE(sd_share->poc_idle_cpus[bit], 0);
			smp_wmb();
		} else {
			atomic64_andnot(1ULL << bit, &sd_share->poc_idle_cpus_mask);
			smp_mb__after_atomic();
			WRITE_ONCE(cpu_rq(cpu)->poc_idle_committed, 1);
		}
	}
}

#define POC_IDLE_CORE(bit)	(core_mask & poc_smt_sibling_mask((bit), sd_share))
#define POC_IDLE_SMT(cpu)	poc_try_idle_smt(base, (cpu), cpu_mask, sd_share)

#define POC_RETURN(cpu, level) do { \
	poc_count(level); \
	poc_commit_selection(cpu, sd_share); \
	return cpu; \
} while (0)

#define POC_RETURN_IF(cpu, level) do { \
	if ((cpu) >= 0) \
		POC_RETURN(cpu, level); \
} while (0)

/**************************************************************
 * Fast path dispatcher:
 */

static __always_inline int select_idle_cpu_poc(int target, int prev,
				int recent, int sync,
				struct sched_domain_shared *sd_share,
				const struct cpumask *allowed)
{
	int base = sd_share->poc_cpu_base;
	int rct_bit = recent - base;
	int tgt_bit = target - base;
	int prv_bit = prev   - base;
#ifdef CONFIG_SCHED_SMT
	u64 core_mask __maybe_unused;
#endif
	u64 affinity;
	u64 cpu_mask;
	int level_offset = 0;

#ifdef CONFIG_SCHED_SMT
	if (sched_smt_active() &&
			static_branch_unlikely(&sched_poc_smt_fallback) &&
			!READ_ONCE(sd_share->has_idle_cores))
		return -1;
#endif

	if (static_branch_unlikely(&sched_poc_lockless_bitmap))
		prefetch(sd_share->poc_idle_cpus);
	else
		prefetch(&sd_share->poc_idle_cpus_mask);

#ifdef CONFIG_SCHED_SMT
	if (sched_smt_active()) {
		if (!static_branch_likely(&sched_poc_smt_uniform)) {
			if (static_branch_unlikely(&sched_poc_lockless_bitmap))
				prefetch(sd_share->poc_idle_cores);
			else
				prefetch(&sd_share->poc_idle_cores_mask);
			if (POC_CPU_VALID(recent))
				prefetch(&sd_share->poc_smt_mask[rct_bit]);
			prefetch(&sd_share->poc_smt_mask[tgt_bit]);
			prefetch(&sd_share->poc_smt_mask[prv_bit]);
		}
	}
#endif
	/* Cluster prefetch removed for 4.14 */
	if (0) prefetch(&sd_share->poc_cluster_mask[tgt_bit]);

	affinity = poc_cpumask_to_u64(allowed, sd_share);
	cpu_mask = poc_idle_cpu_mask(affinity, sd_share);

	if (!cpu_mask)
		return -1;

#ifdef CONFIG_SCHED_SMT
	if (sched_smt_active()) {
		core_mask = poc_idle_core_mask(cpu_mask, sd_share);

		if (!static_branch_likely(&sched_poc_early_select) &&
				core_mask && POC_CPU_IN_LLC(rct_bit) && POC_IDLE_CORE(rct_bit))
			POC_RETURN(recent, POC_LV1R);

		if (static_branch_unlikely(&sched_poc_target_sticky) && POC_IDLE_CPU(tgt_bit))
			POC_RETURN(target, POC_LV1S);

		if (core_mask) {
			if (!static_branch_likely(&sched_poc_early_select) &&
					POC_IDLE_CORE(tgt_bit))
				POC_RETURN(target, POC_LV1T);

			if (prev != target && POC_CPU_IN_LLC(prv_bit) && POC_IDLE_CORE(prv_bit))
				POC_RETURN(prev, POC_LV1P);

			cpu_mask = core_mask;
		} else {
			int cpu;

			if (sync && POC_IDLE_CPU(tgt_bit))
				POC_RETURN(target, POC_LV4S);

			if (prev != target && POC_CPU_IN_LLC(prv_bit)) {
				cpu = POC_IDLE_SMT(prev);
				POC_RETURN_IF(cpu, POC_LV4P);
			}

			cpu = POC_IDLE_SMT(target);
			POC_RETURN_IF(cpu, POC_LV4T);

			if (POC_CPU_IN_LLC(rct_bit)) {
				cpu = POC_IDLE_SMT(recent);
				POC_RETURN_IF(cpu, POC_LV4R);
			}

			level_offset = POC_SMT_LEVEL_OFFSET;
		}
	}
	else
#endif
	{
		if (!static_branch_likely(&sched_poc_early_select) &&
				POC_CPU_IN_LLC(rct_bit) && POC_IDLE_CPU(rct_bit))
			POC_RETURN(recent, POC_LV1R);
		if (POC_IDLE_CPU(tgt_bit))
			POC_RETURN(target, POC_LV1T);
		if (prev != target && POC_CPU_IN_LLC(prv_bit) && POC_IDLE_CPU(prv_bit))
			POC_RETURN(prev, POC_LV1P);
	}

	if (static_branch_likely(&sched_poc_packed)) {
		unsigned int counter = __this_cpu_inc_return(poc_rr_counter);
		int rot = counter & 31;
		u32 cls = 0;
		u32 all;
		u64 packed;
		int raw, bit;

		/* No cluster mapping in 4.14 */
		if (0 && sd_share->poc_cluster_valid)
			cls = ror32((u32)(cpu_mask &
				sd_share->poc_cluster_mask[tgt_bit]), rot);

		all = ror32((u32)cpu_mask, rot);
		packed = (u64)cls | ((u64)all << 32);

		raw = POC_CTZ64(packed);
		bit = ((raw & 31) + rot) & 31;

		POC_RETURN(base + bit, POC_LV2 + (raw >> 5) + level_offset);
	} else {
		if (0 /* no sched_cluster_active in 4.14 */
				&& sd_share->poc_cluster_valid) {
			int cpu = poc_cluster_search(
				base, tgt_bit, sd_share, cpu_mask);
			if (POC_CPU_VALID(cpu))
				POC_RETURN(cpu, POC_LV2 + level_offset);
		}

		{
			unsigned int counter = __this_cpu_inc_return(poc_rr_counter);
			int rr_cpu = poc_select_rr(base, cpu_mask, counter);
			POC_RETURN(rr_cpu, POC_LV3 + level_offset);
		}
	}
}

/**************************************************************
 * Sysctl interface and initialization:
 */

#if defined(CONFIG_SYSCTL)
static void poc_resync_idle_state(void)
{
	int cpu;
	for_each_online_cpu(cpu) {
		WRITE_ONCE(cpu_rq(cpu)->poc_idle_committed, 0);
		__set_cpu_idle_state_poc(cpu, idle_cpu(cpu));
	}
}

static void poc_reevaluate_active(void)
{
	bool want = sched_poc_selector;
	bool now  = static_branch_likely(&poc_selector_active);

	if (want == now)
		return;

	if (want) {
		static_branch_enable(&poc_selector_active);
		poc_resync_idle_state();
	} else {
		static_branch_disable(&poc_selector_active);
	}
}

/* Constants for sysctl 4.14 */
static int zero = 0;
static int one = 1;

static int sched_poc_sysctl_handler(struct ctl_table *table, int write,
				    void __user *buffer, size_t *lenp, loff_t *ppos)
{
	int val = sched_poc_selector ? 1 : 0;
	struct ctl_table tmp = {
		.data    = &val,
		.maxlen  = sizeof(val),
		.extra1  = &zero,
		.extra2  = &one,
	};
	int ret = proc_dointvec_minmax(&tmp, write, buffer, lenp, ppos);

	if (!ret && write) {
		get_online_cpus();
		sched_poc_selector = !!val;
		poc_reevaluate_active();
		put_online_cpus();
	}
	return ret;
}

static int sched_poc_smt_fallback_sysctl_handler(struct ctl_table *table,
					       int write, void __user *buffer,
					       size_t *lenp, loff_t *ppos)
{
	int val = static_branch_unlikely(&sched_poc_smt_fallback) ? 1 : 0;
	struct ctl_table tmp = {
		.data    = &val,
		.maxlen  = sizeof(val),
		.extra1  = &zero,
		.extra2  = &one,
	};
	int ret = proc_dointvec_minmax(&tmp, write, buffer, lenp, ppos);

	if (!ret && write) {
		if (val) static_branch_enable(&sched_poc_smt_fallback);
		else static_branch_disable(&sched_poc_smt_fallback);
	}
	return ret;
}

static int sched_poc_eager_commit_sysctl_handler(struct ctl_table *table,
					     int write, void __user *buffer,
					     size_t *lenp, loff_t *ppos)
{
	int val = static_branch_likely(&sched_poc_eager_commit) ? 1 : 0;
	struct ctl_table tmp = {
		.data    = &val,
		.maxlen  = sizeof(val),
		.extra1  = &zero,
		.extra2  = &one,
	};
	int ret = proc_dointvec_minmax(&tmp, write, buffer, lenp, ppos);

	if (!ret && write) {
		if (val) static_branch_enable(&sched_poc_eager_commit);
		else static_branch_disable(&sched_poc_eager_commit);
	}
	return ret;
}

static int sched_poc_target_sticky_sysctl_handler(struct ctl_table *table,
					       int write, void __user *buffer,
					       size_t *lenp, loff_t *ppos)
{
	int val = static_branch_unlikely(&sched_poc_target_sticky) ? 1 : 0;
	struct ctl_table tmp = {
		.data    = &val,
		.maxlen  = sizeof(val),
		.extra1  = &zero,
		.extra2  = &one,
	};
	int ret = proc_dointvec_minmax(&tmp, write, buffer, lenp, ppos);

	if (!ret && write) {
		if (val) static_branch_enable(&sched_poc_target_sticky);
		else static_branch_disable(&sched_poc_target_sticky);
	}
	return ret;
}

static int sched_poc_early_select_handler(struct ctl_table *table,
					  int write, void __user *buffer,
					  size_t *lenp, loff_t *ppos)
{
	int val = static_branch_likely(&sched_poc_early_select) ? 1 : 0;
	struct ctl_table tmp = {
		.data    = &val,
		.maxlen  = sizeof(val),
		.extra1  = &zero,
		.extra2  = &one,
	};
	int ret = proc_dointvec_minmax(&tmp, write, buffer, lenp, ppos);

	if (!ret && write) {
		if (val) static_branch_enable(&sched_poc_early_select);
		else static_branch_disable(&sched_poc_early_select);
	}
	return ret;
}

static int sched_poc_greedy_search_handler(struct ctl_table *table,
					       int write, void __user *buffer,
					       size_t *lenp, loff_t *ppos)
{
	int val = static_branch_likely(&sched_poc_greedy_search) ? 1 : 0;
	struct ctl_table tmp = {
		.data    = &val,
		.maxlen  = sizeof(val),
		.extra1  = &zero,
		.extra2  = &one,
	};
	int ret = proc_dointvec_minmax(&tmp, write, buffer, lenp, ppos);

	if (!ret && write) {
		if (val) static_branch_enable(&sched_poc_greedy_search);
		else static_branch_disable(&sched_poc_greedy_search);
	}
	return ret;
}

static int sched_poc_count_sysctl_handler(struct ctl_table *table,
					  int write, void __user *buffer,
					  size_t *lenp, loff_t *ppos)
{
	int val = static_branch_unlikely(&sched_poc_count_enabled) ? 1 : 0;
	struct ctl_table tmp = {
		.data    = &val,
		.maxlen  = sizeof(val),
		.extra1  = &zero,
		.extra2  = &one,
	};
	int ret = proc_dointvec_minmax(&tmp, write, buffer, lenp, ppos);

	if (!ret && write) {
		if (val) static_branch_enable(&sched_poc_count_enabled);
		else static_branch_disable(&sched_poc_count_enabled);
	}
	return ret;
}

static int sched_poc_lockless_bitmap_sysctl_handler(struct ctl_table *table,
						int write, void __user *buffer,
						size_t *lenp, loff_t *ppos)
{
	int val = static_branch_unlikely(&sched_poc_lockless_bitmap) ? 1 : 0;
	struct ctl_table tmp = {
		.data    = &val,
		.maxlen  = sizeof(val),
		.extra1  = &zero,
		.extra2  = &one,
	};
	int ret = proc_dointvec_minmax(&tmp, write, buffer, lenp, ppos);

	if (!ret && write) {
		get_online_cpus();
		if (val) static_branch_enable(&sched_poc_lockless_bitmap);
		else static_branch_disable(&sched_poc_lockless_bitmap);
		poc_resync_idle_state();
		put_online_cpus();
	}
	return ret;
}

static struct ctl_table sched_poc_sysctls[] = {
	{
		.procname	= "sched_poc_selector",
		.data		= NULL,
		.maxlen		= sizeof(int),
		.mode		= 0644,
		.proc_handler	= sched_poc_sysctl_handler,
	},
	{
		.procname	= "sched_poc_smt_fallback",
		.data		= NULL,
		.maxlen		= sizeof(int),
		.mode		= 0644,
		.proc_handler	= sched_poc_smt_fallback_sysctl_handler,
	},
	{
		.procname	= "sched_poc_eager_commit",
		.data		= NULL,
		.maxlen		= sizeof(int),
		.mode		= 0644,
		.proc_handler	= sched_poc_eager_commit_sysctl_handler,
	},
	{
		.procname	= "sched_poc_target_sticky",
		.data		= NULL,
		.maxlen		= sizeof(int),
		.mode		= 0644,
		.proc_handler	= sched_poc_target_sticky_sysctl_handler,
	},
	{
		.procname	= "sched_poc_early_select",
		.data		= NULL,
		.maxlen		= sizeof(int),
		.mode		= 0644,
		.proc_handler	= sched_poc_early_select_handler,
	},
	{
		.procname	= "sched_poc_greedy_search",
		.data		= NULL,
		.maxlen		= sizeof(int),
		.mode		= 0644,
		.proc_handler	= sched_poc_greedy_search_handler,
	},
	{
		.procname	= "sched_poc_count",
		.data		= NULL,
		.maxlen		= sizeof(int),
		.mode		= 0644,
		.proc_handler	= sched_poc_count_sysctl_handler,
	},
	{
		.procname	= "sched_poc_lockless_bitmap",
		.data		= NULL,
		.maxlen		= sizeof(int),
		.mode		= 0644,
		.proc_handler	= sched_poc_lockless_bitmap_sysctl_handler,
	},
	{ }
};

static struct ctl_table_header *poc_sysctl_header;

static int __init sched_poc_sysctl_init(void)
{
	printk(KERN_INFO "%s %s by %s [CTZ: %s, PTSelect: %s]\n",
		SCHED_POC_SELECTOR_PROGNAME, SCHED_POC_SELECTOR_VERSION,
		SCHED_POC_SELECTOR_AUTHOR, POC_CTZ64_NAME, POC_PTSELECT_NAME);

	poc_sysctl_header = register_sysctl_paths(
		(struct ctl_path[]){ { .procname = "kernel", }, { } }, 
		sched_poc_sysctls
	);
	return 0;
}
late_initcall(sched_poc_sysctl_init);

#endif /* CONFIG_SYSCTL */

static int __init sched_poc_rr_init(void)
{
	int cpu;
	for_each_possible_cpu(cpu)
		per_cpu(poc_rr_counter, cpu) = (u32)cpu;
	return 0;
}
early_initcall(sched_poc_rr_init);

/**************************************************************
 * Status: sysfs interface
 */

#ifdef CONFIG_SYSFS

static struct kobject *kobj_poc_root;

static bool poc_check_all_llc_eligible(void)
{
	int cpu;
	for_each_online_cpu(cpu) {
		struct sched_domain_shared *sd_share;

		rcu_read_lock();
		sd_share = rcu_dereference(per_cpu(sd_llc_shared, cpu));
		if (sd_share && !sd_share->poc_fast_eligible) {
			rcu_read_unlock();
			return false;
		}
		rcu_read_unlock();
	}
	return true;
}

static ssize_t active_show(struct kobject *kobj,
			   struct kobj_attribute *attr, char *buf)
{
	bool active = static_branch_likely(&poc_selector_active) &&
		      poc_check_all_llc_eligible();
	return snprintf(buf, PAGE_SIZE, "%d\n", active ? 1 : 0);
}

static ssize_t symmetric_cpucap_show(struct kobject *kobj,
				     struct kobj_attribute *attr, char *buf)
{
	/* 4.14 uses symmetric cpucap conceptually here */
	return snprintf(buf, PAGE_SIZE, "1\n");
}

static ssize_t all_llc_eligible_show(struct kobject *kobj,
				     struct kobj_attribute *attr, char *buf)
{
	return snprintf(buf, PAGE_SIZE, "%d\n", poc_check_all_llc_eligible() ? 1 : 0);
}

static ssize_t version_show(struct kobject *kobj,
			    struct kobj_attribute *attr, char *buf)
{
	return snprintf(buf, PAGE_SIZE, "%s\n", SCHED_POC_SELECTOR_VERSION);
}

static struct kobj_attribute poc_status_active_attr = __ATTR_RO(active);
static struct kobj_attribute poc_status_asym_attr = __ATTR_RO(symmetric_cpucap);
static struct kobj_attribute poc_status_eligible_attr = __ATTR_RO(all_llc_eligible);
static struct kobj_attribute poc_status_version_attr = __ATTR_RO(version);

static struct attribute *poc_status_attrs[] = {
	&poc_status_active_attr.attr,
	&poc_status_asym_attr.attr,
	&poc_status_eligible_attr.attr,
	&poc_status_version_attr.attr,
	NULL,
};

static const struct attribute_group poc_status_group = {
	.name = "status",
	.attrs = poc_status_attrs,
};

#define DEFINE_POC_HW_ATTR(fname, namestr) \
static ssize_t poc_hw_##fname##_show(struct kobject *kobj, \
		struct kobj_attribute *attr, char *buf) \
{ \
	return snprintf(buf, PAGE_SIZE, "%s\n", namestr); \
} \
static struct kobj_attribute poc_hw_attr_##fname = { \
	.attr = { .name = #fname, .mode = 0444 }, \
	.show = poc_hw_##fname##_show, \
}

DEFINE_POC_HW_ATTR(ctz, POC_CTZ64_NAME);
DEFINE_POC_HW_ATTR(ptselect, POC_PTSELECT_NAME);

static ssize_t poc_hw_popcnt_show(struct kobject *kobj,
				  struct kobj_attribute *attr, char *buf)
{
#if defined(__x86_64__)
	return snprintf(buf, PAGE_SIZE, "%s\n",
		boot_cpu_has(X86_FEATURE_POPCNT) ? "HW (POPCNT)" : "SW");
#elif defined(__aarch64__)
	return snprintf(buf, PAGE_SIZE, "HW (CNT)\n");
#elif defined(__riscv) && defined(__riscv_zbb)
	return snprintf(buf, PAGE_SIZE, "HW (cpop)\n");
#else
	return snprintf(buf, PAGE_SIZE, "SW\n");
#endif
}

static struct kobj_attribute poc_hw_attr_popcnt = {
	.attr = { .name = "popcnt", .mode = 0444 },
	.show = poc_hw_popcnt_show,
};

static struct attribute *poc_hw_attrs[] = {
	&poc_hw_attr_popcnt.attr,
	&poc_hw_attr_ctz.attr,
	&poc_hw_attr_ptselect.attr,
	NULL,
};

static const struct attribute_group poc_hw_group = {
	.name = "hw_accel",
	.attrs = poc_hw_attrs,
};

static unsigned long poc_sum_level(enum poc_level lvl)
{
	unsigned long sum = 0;
	int cpu;
	for_each_possible_cpu(cpu)
		sum += per_cpu(poc_debug_cnt[lvl], cpu);
	return sum;
}

#define DEFINE_POC_COUNT_ATTR(fname, level)				\
static ssize_t poc_count_##fname##_show(struct kobject *kobj,	\
		struct kobj_attribute *attr, char *buf)			\
{									\
	return snprintf(buf, PAGE_SIZE, "%lu\n", poc_sum_level(level));	\
}									\
static struct kobj_attribute poc_count_##fname##_attr = {		\
	.attr = { .name = #fname, .mode = 0444 },			\
	.show = poc_count_##fname##_show,				\
}

DEFINE_POC_COUNT_ATTR(l1s, POC_LV1S);
DEFINE_POC_COUNT_ATTR(l1t, POC_LV1T);
DEFINE_POC_COUNT_ATTR(l1p, POC_LV1P);
DEFINE_POC_COUNT_ATTR(l1r, POC_LV1R);
DEFINE_POC_COUNT_ATTR(l2, POC_LV2);
DEFINE_POC_COUNT_ATTR(l3, POC_LV3);
DEFINE_POC_COUNT_ATTR(l4s, POC_LV4S);
DEFINE_POC_COUNT_ATTR(l4p, POC_LV4P);
DEFINE_POC_COUNT_ATTR(l4r, POC_LV4R);
DEFINE_POC_COUNT_ATTR(l4t, POC_LV4T);
DEFINE_POC_COUNT_ATTR(l5, POC_LV5);
DEFINE_POC_COUNT_ATTR(l6, POC_LV6);
DEFINE_POC_COUNT_ATTR(fallback, POC_FALLBACK);

static ssize_t poc_count_reset_store(struct kobject *kobj,
		struct kobj_attribute *attr,
		const char *buf, size_t count)
{
	int cpu;
	for_each_possible_cpu(cpu)
		memset(per_cpu_ptr(poc_debug_cnt, cpu), 0,
		       sizeof(poc_debug_cnt));
	return count;
}

static struct kobj_attribute poc_count_reset_attr = {
	.attr = { .name = "reset", .mode = 0200 },
	.store = poc_count_reset_store,
};

static struct attribute *poc_count_attrs[] = {
	&poc_count_l1s_attr.attr,
	&poc_count_l1t_attr.attr,
	&poc_count_l1p_attr.attr,
	&poc_count_l1r_attr.attr,
	&poc_count_l2_attr.attr,
	&poc_count_l3_attr.attr,
	&poc_count_l4s_attr.attr,
	&poc_count_l4p_attr.attr,
	&poc_count_l4r_attr.attr,
	&poc_count_l4t_attr.attr,
	&poc_count_l5_attr.attr,
	&poc_count_l6_attr.attr,
	&poc_count_fallback_attr.attr,
	&poc_count_reset_attr.attr,
	NULL,
};

static const struct attribute_group poc_count_group = {
	.name = "count",
	.attrs = poc_count_attrs,
};

static int __init sched_poc_status_init(void)
{
	int ret;

	kobj_poc_root = kobject_create_and_add("poc_selector", kernel_kobj);
	if (!kobj_poc_root)
		return -ENOMEM;

	ret = sysfs_create_group(kobj_poc_root, &poc_status_group);
	if (ret) goto err_status;

	ret = sysfs_create_group(kobj_poc_root, &poc_hw_group);
	if (ret) goto err_hw;

	ret = sysfs_create_group(kobj_poc_root, &poc_count_group);
	if (ret) goto err_selected;

	return 0;

err_selected:
	sysfs_remove_group(kobj_poc_root, &poc_hw_group);
err_hw:
	sysfs_remove_group(kobj_poc_root, &poc_status_group);
err_status:
	kobject_put(kobj_poc_root);
	kobj_poc_root = NULL;
	return ret;
}
late_initcall(sched_poc_status_init);

#endif /* CONFIG_SYSFS */
#endif /* CONFIG_SCHED_POC_SELECTOR */
