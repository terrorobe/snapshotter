# snapshotter

snapshotter is a LVM-based tool which helps you to automatically create a snapshot of your complete mounted filesystem tree which you then can use as source for consistent backups.

It turns

	/dev/mapper/vg-root on / type ext3 (rw,noatime,errors=remount-ro)
	/dev/sda1 on /boot type ext2 (rw, noatime)
	/dev/mapper/raid5-vzprivate on /var/lib/vz/private type ext3 (rw,noatime)

into

	/dev/mapper/vg-SNAProot on /mnt/backup type ext3 (rw)
	/dev/mapper/raid5-SNAPvzprivate on /mnt/backup/var/lib/vz/private type ext3 (rw)
	/boot on /mnt/backup/boot type none (rw,bind)


This means that it

* Create the directory for the mountpoint /mnt/backup
* Create snapshots of the "root" and "srv" logical volumes
* Mount the snapshots in /mnt/backup and /mnt/backup/srv respectively
* Bind-Mount /boot to /mnt/backup/boot

providing /mnt/backup as an almost atomic snapshot of the current filesystem tree.


### almost?

There are two problems in the above example:


#### Snapshot creation

There's a slight time window between the creation of the snapshots of the root and vzprivate volume, since the creation of snapshot volumes takes a few seconds, depending on hardware and system load.


#### Bind mount

Since /boot resides on a non-LVM blockdevice it can only be bind-mounted in the backup tree, meaning that any changes on the underlying filesystem is instantly reflected in the bind mount.

## Example Usage

Create snapshot of current filesystem tree in /mnt/snapshotbackup excluding /srv/backup:

	snapshotter snapshot /mnt/snapshotbackup --exclude-mountpoints=/srv/backup

Cleaning it up after backup finishes:

	snapshotter teardown /mnt/snapshotbackup

## Requirements

  * lvm2
  * Perl 5.8 or later
  * Linux::LVM
  * Sys::Filesystem
  * File::Which




## Installation Instructions

snapshotter is currently only available via github, to get the most recent stable version use

	git clone https://terrorobe@github.com/terrorobe/snapshotter.git

### Debian

#### Lenny

	apt-get install liblinux-lvm-perl libfile-which-perl dh-make-perl
	dh-make-perl --install --CPAN Sys::Filesystem


## Caveats

  * Linux::LVM is currently a bit verbose. An upstream bug report has already been filed.
  * snapshotter requires free space in any used volume group to work.
