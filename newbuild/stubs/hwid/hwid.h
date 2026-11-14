/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Placeholder for the Xiaomi hardware-id interface. The real implementation
 * (drivers/misc/hwid/hwid.c) is not part of the published source drop.
 *
 * Provide the identifiers used by the USB eUSB2 repeater driver. Returning a
 * value that matches none of the project IDs keeps the proprietary workaround
 * disabled while still allowing the driver to build.
 */
#ifndef __LINUX_MI_HWID_H
#define __LINUX_MI_HWID_H

#define HARDWARE_PROJECT_M2	0x20
#define HARDWARE_PROJECT_M3	0x21
#define HARDWARE_PROJECT_N11	0x22

#define CountryCN		0x01

static inline int get_hw_version_platform(void)
{
	return -1;
}

static inline int get_hw_country_version(void)
{
	return -1;
}

#endif /* __LINUX_MI_HWID_H */
