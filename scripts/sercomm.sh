#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (c) 2021 Mikhail Zhilkin <csharper2005@gmail.com>
# Moded-by: Maximilian Weinmann <x1@disroot.org>
# v2.002
#
### sercomm.sh  - calculates and appends a special tag header & footprint.
###                      Intended for some Sercomm devices (e.g., Beeline
###                      SmartBox GIGA, Beeline SmartBox Turbo+, Sercomm
###                      S3, Beeline SmartBox Pro).
#
# Credits to @kar200 for the header description. More details are here:
# https://forum.openwrt.org/t/add-support-for-sercomm-s3-on-stock-uboot
#
###

pad_zeros () {
	awk '{ printf "%8s\n", $0 }' | sed 's/ /0/g'
}

# Remove leading 0x
trim_hx () {
	printf "%x\n" $1 | pad_zeros
}

# Change endian
swap_hx () {
	pad_zeros | awk '{for (i=7;i>=1;i=i-2) printf "%s%s", substr($1,i,2), \
		(i>1?"":"\n")}'
}

# Check file size
fsize () {
	stat -c "%s" $1
}

# Calculate checksum
chksum () {
	dd if=$1 2>/dev/null | gzip -c | tail -c 8 | od -An -tx4 -N4 --endian=big |\
		tr -d ' \n' | pad_zeros
}

# Write bytes in the tag by offset
write_tag () {
	printf "$(echo $2 | sed 's/../\\x&/g')" | dd of=$FILE_TMP seek=$(($1)) \
		bs=1 conv=notrunc 2>/dev/null
}

# Tag footprint for SerComm S1500
tag_footer_factory () {
	printf 11223344556677889900112233445566 | sed 's/../\\x&/g' | \
		xargs -d . printf | dd of=FOOTPRINT.tmp conv=notrunc 2>/dev/null
}

#######################################
# Tag SerComm pid
# Arguments:
#   SERCOMM_HWVER
#   SERCOMM_0x04str
#   SERCOMM_HWID
#   SERCOMM_0x10str
#   SERCOMM_SWVER
#######################################
tag_sercomm_pid () {
	# ASCII zeros area 0x70
	dd if=/dev/zero count=$((0x70)) iflag=count_bytes 2>/dev/null | \
		tr '\0' '0' | dd of=SERCOMM_PID.tmp 2>/dev/null
	# 0x00 - Hardware version
	printf $SERCOMM_HWVER | dd of=SERCOMM_PID.tmp conv=notrunc 2>/dev/null
	# 0x04 - ? Constant
	printf $SERCOMM_0x04str | dd seek=$((0x4)) of=SERCOMM_PID.tmp bs=1 \
		conv=notrunc 2>/dev/null
	# 0x08 - Hardware ID (ASCII->HEX)
	printf $SERCOMM_HWID | hexdump -e '/1 "%1x"' | dd seek=$((0x8)) \
		of=SERCOMM_PID.tmp bs=1 conv=notrunc 2>/dev/null
	# 0x10 - ? Constant
	printf $SERCOMM_0x10str | dd seek=$((0x10)) of=SERCOMM_PID.tmp bs=1 \
		conv=notrunc 2>/dev/null
	# 0x64 - Software version
	printf $SERCOMM_SWVER | dd seek=$((0x64)) of=SERCOMM_PID.tmp bs=1 \
		conv=notrunc 2>/dev/null
}

#######################################
# Tag Header for Factory
# Globals:
#   KERNEL_IMG
#	ROOTFS_IMG
# Arguments:
#	footprint
#######################################
tag_head_factory () {
	# Paste Sercomm PID
	tag_sercomm_pid
	dd if=SERCOMM_PID.tmp of=$FILE_TMP conv=notrunc 2>/dev/null
	# 0x070 - Size Kernel
	printf $(fsize $KERNEL_IMG) | dd seek=$((0x70)) of=$FILE_TMP bs=1 \
		conv=notrunc 2>/dev/null
	# 0x080 - Size RootFS
	printf $(fsize $ROOTFS_IMG) | dd seek=$((0x80)) of=$FILE_TMP bs=1 \
		conv=notrunc 2>/dev/null
	# 0x090 - Size tag footprint
	if [ -n "$FOOTPRINT_IMG" ]; then
		printf $(fsize $FOOTPRINT_IMG) | dd seek=$((0x90)) of=$FILE_TMP bs=1 \
			conv=notrunc 2>/dev/null
	fi
	# 0x1e0 - MD5 of the rest of the parts
	cat $KERNEL_IMG $ROOTFS_IMG $FOOTPRINT_IMG | md5sum | awk '{print $1;}' | \
		tr -d '\n' | dd seek=$((0x1e0)) of=$FILE_TMP bs=1 \
		conv=notrunc 2>/dev/null
	rm SERCOMM_PID.tmp
}

#######################################
# Tag Header for Kernel
# Globals:
#   KERNEL_IMG
#	ROOTFS_IMG
# Arguments:
#   KERNEL_OFFSET
#	ROOTFS_OFFSET
# Outputs:
#######################################
tag_head_kernel () {
	# Pad 0x100 a new header with 0xffff
	dd if=/dev/zero count=$((0x100)) iflag=count_bytes 2>/dev/null | \
		tr "\0" "\377" > $FILE_TMP

	# Write tag header data
	# 0x04 - Address kernel + Size Kernel
	hdr_kern_len_val=$(fsize $KERNEL_IMG)
	write_tag 0x04 $(trim_hx $(($KERNEL_OFFSET + $hdr_kern_len_val)) | swap_hx)
	# 0x0c - ? Magic constant (0x2ffffff)
	write_tag 0x0c $(trim_hx 0x2ffffff)

	# Write kernel data
	# 0x10 - Address Kernel
	write_tag 0x10 $(trim_hx $KERNEL_OFFSET | swap_hx)
	# 0x14 - Size Kernel
	write_tag 0x14 $(printf "%x\n" $hdr_kern_len_val | pad_zeros | swap_hx)
	# 0x18 - CRC32 Kernel
	write_tag 0x18 $(chksum $KERNEL_IMG)
	# 0x1c - Zeros
	write_tag 0x1c $(trim_hx 0x0)

	# Write rootfs data
	# 0x28 - Address RootFS
	write_tag 0x28 $(trim_hx $ROOTFS_OFFSET | swap_hx)
	# 0x2c - Size RootFS
	write_tag 0x2c $(printf "%x\n" $(fsize $ROOTFS_IMG) | pad_zeros | swap_hx)
	# 0x30 - CRC32 RootFS
	write_tag 0x30 $(chksum $ROOTFS_IMG)
	# 0x34 - Zeros
	write_tag 0x34 $(trim_hx 0x0)

	# 0x08 - Header checksum. 0xffffffff for hdr crc32 calc
	write_tag 0x08 $(chksum $FILE_TMP)
	# 0x00 - Sercomm Signature (0x53657200), 0xffffffff for hdr crc32 calc
	write_tag 0x00 $(trim_hx 0x53657200)
}

print_usage() {
	echo "Usage:"
	echo "Tag Header for Kernel:"
	echo "$0 -a -k <kernel> -r <rootfs> -l <kernel_offset> -s <rootfs_offset> -o <outfile> "
	echo "Tag SerComm pid:"
	echo "$0 -b -g <HWVER> -i <HWID> -j <SWVER> -o <outfile>"
	echo "Tag Header for Factory"
	echo "$0 -c -k <kernel> -r <rootfs> -g <HWVER> -i <HWID> -j <SWVER> -o <outfile>"
	echo "Tag footprint for Factory:"
	echo "$0 -d -o <outfile>"
}

get_tag_head_kernel=false
get_tag_sercomm_pid=false
get_tag_head_factory=false
get_footer_factory=false

while getopts 'abcdg:hi:j:k:l:m:n:o:p:r:s:' flag; do
	case "${flag}" in
		a) get_tag_head_kernel=true ;;
		b) get_tag_sercomm_pid=true ;;
		c) get_tag_head_factory=true ;;
		d) get_footer_factory=true ;;
		g) SERCOMM_HWVER="${OPTARG}" ;;
		i) SERCOMM_HWID="${OPTARG}" ;;
		j) SERCOMM_SWVER="${OPTARG}" ;;
		m) SERCOMM_0x04str="${OPTARG}" ;;
		n) SERCOMM_0x10str="${OPTARG}" ;;
		k) KERNEL_IMG="${OPTARG}" ;;
		l) KERNEL_OFFSET="${OPTARG}" ;;
		r) ROOTFS_IMG="${OPTARG}" ;;
		s) ROOTFS_OFFSET="${OPTARG}" ;;
		o) FILE_OUT="${OPTARG}" ;;
		p) FOOTPRINT_IMG="${OPTARG}" ;;
		h | *) print_usage
			exit 1 ;;
	esac
done

if $get_tag_head_kernel; then
	FILE_TMP=hdrkrn-$KERNEL_OFFSET.tmp
	tag_head_kernel
	mv $FILE_TMP $FILE_OUT
fi
if $get_tag_sercomm_pid; then
	tag_sercomm_pid
	mv SERCOMM_PID.tmp $FILE_OUT
fi
if $get_tag_head_factory; then
	FILE_TMP=headfactory.tmp
	tag_head_factory
	mv $FILE_TMP $FILE_OUT
fi
if $get_footer_factory; then
	tag_footer_factory
	mv FOOTPRINT.tmp $FILE_OUT
fi

# Header Kernel
# ./sercomm.sh \
# 	-a \
# 	-k kern.bin \
# 	-r rootfs.bin \
# 	-l 0x1700100 \
# 	-s 0x1f00000 \
# 	-o /tmp/hdr1.tmp ; xxd -c 4 -l $((0x40)) /tmp/hdr1.tmp

# Header Factory
# ./sercomm.sh \
# 	-c \
# 	-k kern.bin \
# 	-r rootfs.bin \
# 	-p footer.bin \
# 	-g 0001 \
# 	-i AWI \
# 	-j 2121 \
# 	-o /tmp/hdr.factory.tmp ; hexdump -C /tmp/hdr.factory.tmp

# PID
# ./sercomm.sh \
# 	-b \
# 	-g 0001 \
# 	-i AWI \
# 	-j 2121 \
# 	-o /tmp/pid.tmp ; hexdump -C /tmp/pid.tmp

# Footer
# ./sercomm.sh \
# 	-d \
# 	-o /tmp/footer.tmp ; hexdump -C /tmp/footer.tmp
