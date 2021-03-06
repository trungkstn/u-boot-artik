/*
 * Lowlevel setup for XYREF4415 board based on EXYNOS4
 *
 * Copyright (C) 2013 Samsung Electronics
 *
 * See file CREDITS for list of people who contributed to this
 * project.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation; either version 2 of
 * the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston,
 * MA 02111-1307 USA
 */

#include <config.h>
#include <version.h>
#include <asm/arch/cpu.h>

/* Multi Core Timer */
#define G_TCON_OFFSET		0x0240
#define GLOBAL_FRC_ENABLE	0x100

#define PSHOLD_CONTROL_OFFSET	0x330C

_TEXT_BASE:
	.word	CONFIG_SYS_TEXT_BASE

	.globl lowlevel_init
lowlevel_init:
	/* use iRAM stack in bl2 */
	ldr	sp, =CONFIG_IRAM_STACK
	stmdb	r13!, {ip,lr}

	bl	relocate_code

	/* check warm reset status */
	bl	check_warm_reset

	/* check reset status */
	ldr	r0, =(EXYNOS4_POWER_BASE + INFORM1_OFFSET)
	ldr	r1, [r0]

	/* AFTR wakeup reset */
	ldr	r2, =S5P_CHECK_DIDLE
	cmp	r1, r2
	beq	exit_wakeup

	/* LPA wakeup reset */
	ldr	r2, =S5P_CHECK_LPA
	cmp	r1, r2
	beq	exit_wakeup

	/* Sleep wakeup reset */
	ldr	r2, =S5P_CHECK_SLEEP
	cmp	r1, r2
	beq	wakeup_reset

	/* set GPX2[7] to high to hold PMIC power */
	ldr r1, =0x11000C48
	ldr r0, =0x0
	str r0, [r1]
	ldr r1, =0x11000C40
	ldr r0, =0x10000000
	str r0, [r1]
	ldr r1, =0x11000C44
	ldr r0, =0xff
	str r0, [r1]

	/* PS-Hold high */
	ldr	r0, =(EXYNOS4_POWER_BASE + PSHOLD_CONTROL_OFFSET)
	ldr	r1, [r0]
	orr	r1, r1, #0x100
	str	r1, [r0]

#if defined(CONFIG_PM)
	bl	pmic_enable_peric_dev
#endif

	bl	read_om

	/*
	 * If U-boot is already running in RAM, no need to relocate U-Boot.
	 * Memory controller must be configured before relocating U-Boot
	 * in ram.
	 */
	ldr	r0, =0x0ffffff		/* r0 <- Mask Bits*/
	bic	r1, pc, r0		/* pc <- current addr of code */
					/* r1 <- unmasked bits of pc */
	ldr	r2, _TEXT_BASE		/* r2 <- original base addr in ram */
	bic	r2, r2, r0		/* r2 <- unmasked bits of r2*/
	cmp	r1, r2			/* compare r1, r2 */
	beq	1f			/* r0 == r1 then skip sdram init */

#if defined(CONFIG_PM)
	bl	pmic_init
#endif

	/* init system clock */
	bl	system_clock_init

	/* Memory initialize */
	bl	mem_ctrl_init

#if defined(CONFIG_TZPC)
	bl	tzpc_init
#endif

1:
	ldmia	r13!, {ip,pc}

wakeup_reset:
	bl	start_mct_frc

	bl	read_om

	/* If eMMC booting */
	ldr	r0, =(EXYNOS4_POWER_BASE + INFORM3_OFFSET)
	ldr	r1, [r0]
	cmp	r1, #BOOT_EMMC_4_4
	bleq	emmc_endbootop

	/* init system clock */
	bl	system_clock_init

	/* Memory initialize */
	bl	mem_ctrl_init

exit_wakeup:
	b       warmboot

read_om:
	/* Read booting information */
	ldr	r0, =(EXYNOS4_POWER_BASE + OM_STATUS_OFFSET)
	ldr	r1, [r0]
	bic	r2, r1, #0xffffffc1

	/* SD/MMC BOOT */
	cmp     r2, #0x4
	moveq   r3, #BOOT_MMCSD

	/* eMMC BOOT */
	cmp	r2, #0x6
	moveq	r3, #BOOT_EMMC

	/* eMMC 4.4 BOOT */
	cmp	r2, #0x8
	moveq	r3, #BOOT_EMMC_4_4
	cmp	r2, #0x28
	moveq	r3, #BOOT_EMMC_4_4

	ldr	r0, =(EXYNOS4_POWER_BASE + INFORM3_OFFSET)
	str	r3, [r0]

	mov	pc, lr

check_warm_reset:
	/* check reset status */
	ldr	r0, =(EXYNOS4_POWER_BASE + RST_STAT_OFFSET)
	ldr	r1, [r0]
	and	r1, r1, #WRESET
	cmp	r1, #WRESET		@ check warm reset
	/* clear reset_status */
	ldreq	r0, =(EXYNOS4_POWER_BASE + INFORM1_OFFSET)
	moveq	r1, #0x0
	streq	r1, [r0]

	mov	pc, lr

start_mct_frc:
	ldr	r0, =(EXYNOS4_MCT_BASE + G_TCON_OFFSET)
	ldr	r1, [r0]
	orr	r1, r1, #GLOBAL_FRC_ENABLE
	str	r1, [r0]

	mov	pc, lr

/*
 * Relocate code
 */
relocate_code:
	adr	r0, nscode_base			@ r0: source address (start)
	adr	r1, nscode_end			@ r1: source address (end)
	ldr	r2, =CONFIG_PHY_IRAM_NS_BASE	@ r2: target address

1:
	ldmia	r0!, {r3-r6}
	stmia	r2!, {r3-r6}
	cmp	r0, r1
	blt	1b

	.word	0xF57FF04F			@dsb	sy
	.word	0xF57FF06F			@isb	sy

	mov	pc, lr

/******************************************************************************/
/*
 * CPU1, 2, 3 waits here until CPU0 wake it up.
 * - below code is copied to CONFIG_PHY_IRAM_NS_BASE, which is non-secure memory.
 */
nscode_base:
	b	1f
	nop				@ for backward compatibility

	.word	0x0			@ REG0: RESUME_ADDR
	.word	0x0			@ REG1: RESUME_FLAG
	.word	0x0			@ REG2
	.word	0x0			@ REG3
	.word	0x0			@ REG4: RESERVED
_hotplug_addr:
	.word	0x0			@ REG5: CPU1_BOOT_REG
	.word	0x0			@ REG6
_c2_addr:
	.word	0x0			@ REG7: REG_C2_ADDR
_cpu_state:
	.word	0x1			@ CPU0_STATE : RESET
	.word	0x2			@ CPU1_STATE : SECONDARY RESET
	.word	0x2			@ CPU2_STATE : SECONDARY RESET
	.word	0x2			@ CPU3_STATE : SECONDARY RESET
	.word	0x0			@ RESERVED
	.word	0x0			@ RESERVED
	.word	0x0			@ RESERVED
	.word	0x0			@ RESERVED

#define RESET			(1 << 0)
#define SECONDARY_RESET		(1 << 1)
#define HOTPLUG			(1 << 2)
#define C2_STATE		(1 << 3)

1:
	adr	r0, _cpu_state

	mrc	p15, 0, r7, c0, c0, 5	@ read MPIDR
	and	r7, r7, #0xf		@ r7 = cpu id

	/* read the current cpu state */
	ldr	r10, [r0, r7, lsl #2]

ns_svc_entry:
	tst	r10, #C2_STATE
	adrne	r0, _c2_addr
	bne	wait_for_addr

	/* clear INFORM1 for security reason  */
	ldr	r0, =(EXYNOS4_POWER_BASE + INFORM1_OFFSET)
	ldr	r1, [r0]
	cmp	r1, #0x0
	movne	r1, #0x0
	strne	r1, [r0]
	ldrne	r1, =(EXYNOS4_POWER_BASE + INFORM0_OFFSET)
	ldrne	pc, [r1]

	tst	r10, #RESET
	ldrne	pc, =CONFIG_SYS_TEXT_BASE

	adr	r0, _hotplug_addr
wait_for_addr:
	ldr	r1, [r0]
	cmp	r1, #0x0
	bxne	r1
	wfe
	b	wait_for_addr
	.ltorg
nscode_end:

