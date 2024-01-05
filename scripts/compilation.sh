#!/bin/bash
#
# Copyright (c) 2013-2021 Igor Pecovnik, igor.pecovnik@gma**.com
#

# compile_atf
# compile_uboot
# compile_kernel
# compile_sunxi_tools
# process_patch_file
# overlayfs_wrapper

compile_atf()
{
	if [[ $CLEAN_LEVEL == *make* ]]; then
		display_alert "Cleaning" "$ATFSOURCEDIR" "info"
		(cd "${ATFSOURCEDIR}"; make distclean > /dev/null 2>&1)
	fi

	cd "$ATFSOURCEDIR" 

	display_alert "Compiling ATF" "" "info"
	display_alert "Compiler version" "${ATF_COMPILER}gcc $(eval env PATH="${toolchain}:${PATH}" "${ATF_COMPILER}gcc" -dumpversion)" "info"

	local target_make target_patchdir target_files
	target_make=$(cut -d';' -f1 <<< "${ATF_TARGET_MAP}")
	target_patchdir=$(cut -d';' -f2 <<< "${ATF_TARGET_MAP}")
	target_files=$(cut -d';' -f3 <<< "${ATF_TARGET_MAP}")

	echo -e "\n\t==  atf  ==\n" >> "${DEST}"/${LOG_SUBPATH}/compilation.log
	# ENABLE_BACKTRACE="0" has been added to workaround a regression in ATF.

	eval CCACHE_BASEDIR="$(pwd)" env PATH="${toolchain}:${PATH}" \
		'make ENABLE_BACKTRACE="0" $target_make $CTHREADS \
		CROSS_COMPILE="$CCACHE $ATF_COMPILER"' 2>> "${DEST}"/${LOG_SUBPATH}/compilation.log \
		${PROGRESS_LOG_TO_FILE:+' | tee -a $DEST/${LOG_SUBPATH}/compilation.log'} \
		${OUTPUT_DIALOG:+' | dialog --backtitle "$backtitle" --progressbox "Compiling ATF..." $TTY_Y $TTY_X'} \
		${OUTPUT_VERYSILENT:+' >/dev/null 2>/dev/null'}

	[[ ${PIPESTATUS[0]} -ne 0 ]] && exit_with_error "ATF compilation failed"

	[[ $(type -t atf_custom_postprocess) == function ]] && atf_custom_postprocess

	atftempdir=$(mktemp -d)
	chmod 700 ${atftempdir}
	trap "rm -rf \"${atftempdir}\" ; exit 0" 0 1 2 3 15

	# copy files to temp directory
	for f in $target_files; do
		local f_src
		f_src=$(cut -d':' -f1 <<< "${f}")
		if [[ $f == *:* ]]; then
			local f_dst
			f_dst=$(cut -d':' -f2 <<< "${f}")
		else
			local f_dst
			f_dst=$(basename "${f_src}")
		fi
		[[ ! -f $f_src ]] && exit_with_error "ATF file not found" "$(basename "${f_src}")"
		cp "${f_src}" "${atftempdir}/${f_dst}"
	done

	# copy license file to pack it to u-boot package later
	[[ -f license.md ]] && cp license.md "${atftempdir}"/
}

compile_uboot()
{
	# not optimal, but extra cleaning before overlayfs_wrapper should keep sources directory clean
	if [[ $CLEAN_LEVEL == *make* ]]; then
		display_alert "Cleaning" "$BOOTSOURCEDIR" "info"
		(cd $BOOTSOURCEDIR; make clean > /dev/null 2>&1)
	fi

	local ubootdir="$BOOTSOURCEDIR"

	cd "${ubootdir}" || exit

	display_alert "Compiling u-boot" "${BOOTBRANCH}" "info"
	display_alert "Compiler version" "${UBOOT_COMPILER}gcc $(eval env PATH="${toolchain}:${PATH}" "${UBOOT_COMPILER}gcc" -dumpversion)" "info"

	# create directory structure for the .deb package
	uboottempdir=$(mktemp -d)
	chmod 700 ${uboottempdir}
	trap "ret=\$?; rm -rf \"${uboottempdir}\" ; exit \$ret" 0 1 2 3 15
	local uboot_name=${CHOSEN_UBOOT}_${REVISION}_${ARCH}
	rm -rf $uboottempdir/$uboot_name
	mkdir -p $uboottempdir/$uboot_name/usr/lib/{u-boot,$uboot_name} $uboottempdir/$uboot_name/DEBIAN

	# process compilation for one or multiple targets
	while read -r target; do
		local target_make target_patchdir target_files
		target_make=$(cut -d';' -f1 <<< "${target}")
		target_patchdir=$(cut -d';' -f2 <<< "${target}")
		target_files=$(cut -d';' -f3 <<< "${target}")

		if [[ $CLEAN_LEVEL == *make* ]]; then
			display_alert "Cleaning" "$BOOTSOURCEDIR" "info"
			(cd "${BOOTSOURCEDIR}"; make clean > /dev/null 2>&1)
		fi

		if [[ -n $ATFSOURCE ]]; then
			cp -Rv "${atftempdir}"/*.bin .
			rm -rf "${atftempdir}"
		fi

		echo -e "\n\t== u-boot make $BOOTCONFIG ==\n" >> "${DEST}"/${LOG_SUBPATH}/compilation.log
		eval CCACHE_BASEDIR="$(pwd)" env PATH="${toolchain}:${PATH}" \
			'make ARCH="arm" $CTHREADS $BOOTCONFIG \
			CROSS_COMPILE="$CCACHE $UBOOT_COMPILER"' 2>> "${DEST}"/${LOG_SUBPATH}/compilation.log \
			${PROGRESS_LOG_TO_FILE:+' | tee -a $DEST/${LOG_SUBPATH}/compilation.log'} \
			${OUTPUT_VERYSILENT:+' >/dev/null 2>/dev/null'}

        [[ -f tools/logos/udoo.bmp ]] && cp "${EXTER}"/packages/blobs/splash/udoo.bmp tools/logos/udoo.bmp
        touch .scmversion

        # $BOOTDELAY can be set in board family config, ensure autoboot can be stopped even if set to 0
        [[ $BOOTDELAY == 0 ]] && echo -e "CONFIG_ZERO_BOOTDELAY_CHECK=y" >> .config
        [[ -n $BOOTDELAY ]] && sed -i "s/^CONFIG_BOOTDELAY=.*/CONFIG_BOOTDELAY=${BOOTDELAY}/" .config || [[ -f .config ]] && echo "CONFIG_BOOTDELAY=${BOOTDELAY}" >> .config

		# workaround when two compilers are needed
		cross_compile="CROSS_COMPILE=$CCACHE $UBOOT_COMPILER";

		echo -e "\n\t== u-boot make $target_make ==\n" >> "${DEST}"/${LOG_SUBPATH}/compilation.log
		eval CCACHE_BASEDIR="$(pwd)" env PATH="${toolchain}:${PATH}" \
			'make $target_make $CTHREADS \
			"${cross_compile}"' 2>>"${DEST}"/${LOG_SUBPATH}/compilation.log \
			${PROGRESS_LOG_TO_FILE:+' | tee -a "${DEST}"/${LOG_SUBPATH}/compilation.log'} \
			${OUTPUT_DIALOG:+' | dialog --backtitle "$backtitle" --progressbox "Compiling u-boot..." $TTY_Y $TTY_X'} \
			${OUTPUT_VERYSILENT:+' >/dev/null 2>/dev/null'} ';EVALPIPE=(${PIPESTATUS[@]})'

		[[ ${EVALPIPE[0]} -ne 0 ]] && exit_with_error "U-boot compilation failed"

		[[ $(type -t uboot_custom_postprocess) == function ]] && uboot_custom_postprocess

		# copy files to build directory
		for f in $target_files; do
			local f_src
			f_src=$(cut -d':' -f1 <<< "${f}")
			if [[ $f == *:* ]]; then
				local f_dst
				f_dst=$(cut -d':' -f2 <<< "${f}")
			else
				local f_dst
				f_dst=$(basename "${f_src}")
			fi
			[[ ! -f $f_src ]] && exit_with_error "U-boot file not found" "$(basename "${f_src}")"
			cp "${f_src}" "$uboottempdir/${uboot_name}/usr/lib/${uboot_name}/${f_dst}"
		done
	done <<< "$UBOOT_TARGET_MAP"

	if [[ $PACK_UBOOT == "yes" ]];then
        pack_uboot
        cp $uboottempdir/packout/{boot0_sdcard.fex,boot_package.fex} "${SRC}/.tmp/${uboot_name}/usr/lib/${uboot_name}/"
        cp $uboottempdir/packout/dts/${BOARD}-u-boot.dts "${SRC}/.tmp/${uboot_name}/usr/lib/u-boot/"

		cd "${ubootdir}" || exit
	fi

	# declare -f on non-defined function does not do anything
	cat <<-EOF > "$uboottempdir/${uboot_name}/usr/lib/u-boot/platform_install.sh"
	DIR=/usr/lib/$uboot_name
	$(declare -f write_uboot_platform)
	$(declare -f write_uboot_platform_mtd)
	$(declare -f setup_write_uboot_platform)
	EOF

	# set up control file
	cat <<-EOF > "$uboottempdir/${uboot_name}/DEBIAN/control"
	Package: linux-u-boot-${BOARD}-${BRANCH}
	Version: $REVISION
	Architecture: $ARCH
	Maintainer: $MAINTAINER <$MAINTAINERMAIL>
	Installed-Size: 1
	Section: kernel
	Priority: optional
	Provides: armbian-u-boot
	Replaces: armbian-u-boot
	Conflicts: armbian-u-boot, u-boot-sunxi
	Description: Das U-Boot for ${BOARD}
	EOF

	# copy config file to the package
	# useful for FEL boot with overlayfs_wrapper
	[[ -f .config && -n $BOOTCONFIG ]] && cp .config "$uboottempdir/${uboot_name}/usr/lib/u-boot/${BOOTCONFIG}"
	# copy license files from typical locations
	[[ -f COPYING ]] && cp COPYING "$uboottempdir/${uboot_name}/usr/lib/u-boot/LICENSE"
	[[ -f Licenses/README ]] && cp Licenses/README "$uboottempdir/${uboot_name}/usr/lib/u-boot/LICENSE"
	[[ -n $atftempdir && -f $atftempdir/license.md ]] && cp "${atftempdir}/license.md" "$uboottempdir/${uboot_name}/usr/lib/u-boot/LICENSE.atf"

	display_alert "Building deb" "${uboot_name}.deb" "info"
	fakeroot dpkg-deb -Z xz -b "$uboottempdir/${uboot_name}" "$uboottempdir/${uboot_name}.deb" >> "${DEST}"/${LOG_SUBPATH}/output.log 2>&1
	rm -rf "$uboottempdir/${uboot_name}"
	[[ -n $atftempdir ]] && rm -rf "${atftempdir}"

	[[ ! -f $uboottempdir/${uboot_name}.deb ]] && exit_with_error "Building u-boot package failed"

	rsync --remove-source-files -rq "$uboottempdir/${uboot_name}.deb" "${DEB_STORAGE}/u-boot/"
	rm -rf "$uboottempdir"
}

compile_kernel()
{
	if [[ $CLEAN_LEVEL == *make* ]]; then
		display_alert "Cleaning" "$LINUXSOURCEDIR" "info"
		(cd ${LINUXSOURCEDIR}; make ARCH="${ARCHITECTURE}" clean >/dev/null 2>&1)
	fi

	cd "${LINUXSOURCEDIR}" || exit

	# build 3rd party drivers
	# compilation_prepare
	display_alert "Compiling $BRANCH kernel" "5.16.17" "info"
	display_alert "Compiler version" "${KERNEL_COMPILER}gcc $(eval env PATH="${toolchain}:${PATH}" "${KERNEL_COMPILER}gcc" -dumpversion)" "info"

	# copy kernel config
	if [[ $KERNEL_KEEP_CONFIG == yes && -f "${DEST}"/config/$LINUXCONFIG.config ]]; then
		display_alert "Using previous kernel config" "${DEST}/config/$LINUXCONFIG.config" "info"
		cp -p "${DEST}/config/${LINUXCONFIG}.config" .config
	else
		display_alert "Using kernel config file" "${EXTER}/config/kernel/$LINUXCONFIG.config" "info"
		cp -p "${EXTER}/config/kernel/${LINUXCONFIG}.config" .config
	fi

	if [[ $KERNEL_CONFIGURE != yes ]]; then
        # TODO: check if required
        eval CCACHE_BASEDIR="$(pwd)" env PATH="${toolchain}:${PATH}" \
            'make ARCH=$ARCHITECTURE CROSS_COMPILE="$CCACHE $KERNEL_COMPILER" olddefconfig'
	else
		eval CCACHE_BASEDIR="$(pwd)" env PATH="${toolchain}:${PATH}" \
			'make $CTHREADS ARCH=$ARCHITECTURE CROSS_COMPILE="$CCACHE $KERNEL_COMPILER" oldconfig'
		eval CCACHE_BASEDIR="$(pwd)" env PATH="${toolchain}:${PATH}" \
			'make $CTHREADS ARCH=$ARCHITECTURE CROSS_COMPILE="$CCACHE $KERNEL_COMPILER" ${KERNEL_MENUCONFIG:-menuconfig}'

		[[ ${PIPESTATUS[0]} -ne 0 ]] && exit_with_error "Error kernel menuconfig failed"

		# store kernel config in easily reachable place
		display_alert "Exporting new kernel config" "$DEST/config/$LINUXCONFIG.config" "info"
		cp .config "${DEST}/config/${LINUXCONFIG}.config"
		cp .config "${EXTER}/config/kernel/${LINUXCONFIG}.config"
		# export defconfig too if requested
		if [[ $KERNEL_EXPORT_DEFCONFIG == yes ]]; then
			eval CCACHE_BASEDIR="$(pwd)" env PATH="${toolchain}:${PATH}" \
				'make ARCH=$ARCHITECTURE CROSS_COMPILE="$CCACHE $KERNEL_COMPILER" savedefconfig'
			[[ -f defconfig ]] && cp defconfig "${DEST}/config/${LINUXCONFIG}.defconfig"
		fi
	fi

	echo -e "\n\t== kernel ==\n" >> "${DEST}"/${LOG_SUBPATH}/compilation.log
	eval CCACHE_BASEDIR="$(pwd)" env PATH="${toolchain}:${PATH}" \
		'make $CTHREADS ARCH=$ARCHITECTURE \
		CROSS_COMPILE="$CCACHE $KERNEL_COMPILER" \
		$SRC_LOADADDR \
		LOCALVERSION="-$LINUXFAMILY" \
		$KERNEL_IMAGE_TYPE ${KERNEL_EXTRA_TARGETS:-modules dtbs} 2>>$DEST/${LOG_SUBPATH}/compilation.log' \
		${PROGRESS_LOG_TO_FILE:+' | tee -a $DEST/${LOG_SUBPATH}/compilation.log'} \
		${OUTPUT_DIALOG:+' | dialog --backtitle "$backtitle" \
		--progressbox "Compiling kernel..." $TTY_Y $TTY_X'} \
		${OUTPUT_VERYSILENT:+' >/dev/null 2>/dev/null'}

	if [[ ${PIPESTATUS[0]} -ne 0 || ! -f arch/$ARCHITECTURE/boot/$KERNEL_IMAGE_TYPE ]]; then
		grep -i error $DEST/${LOG_SUBPATH}/compilation.log
		exit_with_error "Kernel was not built" "@host"
	fi

	local kernel_packing="bindeb-pkg"

	display_alert "Creating packages"

	# produce deb packages: image, headers, firmware, dtb
	echo -e "\n\t== deb packages: image, headers, firmware, dtb ==\n" >> "${DEST}"/${LOG_SUBPATH}/compilation.log

	eval CCACHE_BASEDIR="$(pwd)" env PATH="${toolchain}:${PATH}" \
		'make $CTHREADS $kernel_packing \
		KDEB_PKGVERSION=$REVISION \
		KDEB_COMPRESS=${DEB_COMPRESS} \
		BRANCH=$BRANCH \
		LOCALVERSION="-${LINUXFAMILY}" \
		KBUILD_DEBARCH=$ARCH \
		ARCH=$ARCHITECTURE \
		DEBFULLNAME="$MAINTAINER" \
		DEBEMAIL="$MAINTAINERMAIL" \
		CROSS_COMPILE="$CCACHE $KERNEL_COMPILER" 2>>$DEST/${LOG_SUBPATH}/compilation.log' \
		${PROGRESS_LOG_TO_FILE:+' | tee -a $DEST/${LOG_SUBPATH}/compilation.log'} \
		${OUTPUT_DIALOG:+' | dialog --backtitle "$backtitle" --progressbox "Creating kernel packages..." $TTY_Y $TTY_X'} \
		${OUTPUT_VERYSILENT:+' >/dev/null 2>/dev/null'}

	cd .. || exit

	# remove firmare image packages here - easier than patching ~40 packaging scripts at once
	rm -f linux-firmware-image-*.deb

	rsync --remove-source-files -rq ./*.deb "${DEB_STORAGE}/" || exit_with_error "Failed moving kernel DEBs"
}

compile_sunxi_tools()
{
	# Compile and install only if git commit changed
	cd $EXTER/cache/sources/sunxi-tools || exit
	# need to check if /usr/local/bin/sunxi-fexc to detect new Docker containers with old cached sources
    
    display_alert "Compiling" "sunxi-tools" "info"
    make -s clean >/dev/null
    make -s tools >/dev/null
    mkdir -p /usr/local/bin/
    make install-tools >/dev/null 2>&1
}

overlayfs_wrapper()
{
	local operation="$1"
	if [[ $operation == wrap ]]; then
		local srcdir="$2"
		local description="$3"
		mkdir -p /tmp/overlay_components/ /tmp/armbian_build/
		local tempdir workdir mergeddir
		tempdir=$(mktemp -d --tmpdir="/tmp/overlay_components/")
		workdir=$(mktemp -d --tmpdir="/tmp/overlay_components/")
		mergeddir=$(mktemp -d --suffix="_$description" --tmpdir="/tmp/armbian_build/")
		mount -t overlay overlay -o lowerdir="$srcdir",upperdir="$tempdir",workdir="$workdir" "$mergeddir"
		# this is executed in a subshell, so use temp files to pass extra data outside
		echo "$tempdir" >> /tmp/.overlayfs_wrapper_cleanup
		echo "$mergeddir" >> /tmp/.overlayfs_wrapper_umount
		echo "$mergeddir" >> /tmp/.overlayfs_wrapper_cleanup
		echo "$mergeddir"
		return
	fi
	if [[ $operation == cleanup ]]; then
		if [[ -f /tmp/.overlayfs_wrapper_umount ]]; then
			for dir in $(</tmp/.overlayfs_wrapper_umount); do
				[[ $dir == /tmp/* ]] && umount -l "$dir" > /dev/null 2>&1
			done
		fi
		if [[ -f /tmp/.overlayfs_wrapper_cleanup ]]; then
			for dir in $(</tmp/.overlayfs_wrapper_cleanup); do
				[[ $dir == /tmp/* ]] && rm -rf "$dir"
			done
		fi
		rm -f /tmp/.overlayfs_wrapper_umount /tmp/.overlayfs_wrapper_cleanup
	fi
}
