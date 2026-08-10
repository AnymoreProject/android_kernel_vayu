// SPDX-License-Identifier: GPL-2.0
/*
 * Infinity Charging Control Driver
 * Poco X3 Pro (vayu/bhima)
 */

#include <linux/module.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/fs.h>
#include <linux/uaccess.h>
#include <linux/power_supply.h>

#define INFINITY_CHARGING_CONTROL "infinity_charging_control"

static int charging_enabled = 1;
static int charging_current = 1800;

static ssize_t charging_enable_show(struct device *dev,
                                     struct device_attribute *attr, char *buf)
{
	return snprintf(buf, PAGE_SIZE, "%d\n", charging_enabled);
}

static ssize_t charging_enable_store(struct device *dev,
                                      struct device_attribute *attr,
                                      const char *buf, size_t count)
{
	int val;
	if (kstrtoint(buf, 10, &val) == 0)
		charging_enabled = val ? 1 : 0;
	return count;
}

static DEVICE_ATTR(charging_enabled, 0644, charging_enable_show,
		   charging_enable_store);

static struct attribute *infinity_attrs[] = {
	&dev_attr_charging_enabled.attr,
	NULL,
};

static struct attribute_group infinity_attr_group = {
	.attrs = infinity_attrs,
};

static struct kobject *infinity_kobj;

static int __init infinity_charging_init(void)
{
	int ret;
	infinity_kobj = kobject_create_and_add(INFINITY_CHARGING_CONTROL,
						 kernel_kobj);
	if (!infinity_kobj)
		return -ENOMEM;
	ret = sysfs_create_group(infinity_kobj, &infinity_attr_group);
	if (ret)
		kobject_put(infinity_kobj);
	pr_info("Infinity Charging Control: initialized\n");
	return ret;
}

static void __exit infinity_charging_exit(void)
{
	kobject_put(infinity_kobj);
	pr_info("Infinity Charging Control: exited\n");
}

module_init(infinity_charging_init);
module_exit(infinity_charging_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Infinity Kernel Team");
MODULE_DESCRIPTION("Infinity Charging Control for Poco X3 Pro");