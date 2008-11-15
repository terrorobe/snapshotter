#!/usr/bin/perl -w

use strict;

use Sys::Filesystem ();
use Linux::LVM;
use POSIX qw(ceil);
use Getopt::Compact;

use Data::Dumper;
use Carp;

my %excluded_mountpoints;
my %excluded_volumes = ('/dev/raid5/backup' => 1);
my %included_filesystems = ('ext3' => 1);
my $snapshot_size_percentage = '10';
my $snapshot_path = '/mnt/snapbackup';
my $snapshot_lv_prefix = 'SNAP';

my %vgs;
my %lvs;
my %fs;
my %snapshot_filesystems;

my $mode = 'teardown';


collect_lvm_information();
collect_filesystems();

if ($mode eq 'snapshot') {

    %snapshot_filesystems = build_filesystem_list();
    check_free_space();

    create_mount_directory();
    create_snapshots();
    mount_snapshots();

} elsif ($mode eq 'teardown') {

    unmount_snapshots();
    remove_snapshots();
    remove_mount_directory();

} else {

    croak "Unknown mode";

}

#print Dumper \%snapshot_filesystems;
#print Dumper \%vgs;
#print Dumper \%lvs;


sub unmount_snapshots {

    for my $device (keys %fs) {
        my $mountpoint = $fs{$device}->{'mountpoint'};

        if ($mountpoint =~ m/^$snapshot_path/) {
            $snapshot_filesystems{$device} = $fs{$device};
        }
    }

    for my $device (reverse sort by_mountpoint_length keys %snapshot_filesystems) {
        my $mountpoint = $snapshot_filesystems{$device}->{'mountpoint'};
        print "umount $mountpoint\n";
    }
}

sub remove_snapshots {
#FIXME: No snapshot detection possible?!
    for my $device (keys %lvs) {
        if ($device =~ m{/$snapshot_lv_prefix}) {
            print "lvremove --force $device\n";
        }
    }
}

sub remove_mount_directory {
    rmdir $snapshot_path or croak "Failed to remove Snapshot Path $snapshot_path: $1";
}

sub create_mount_directory {

    croak "Snapshot Path $snapshot_path already exists" if (-d $snapshot_path);

    mkdir $snapshot_path or croak "Failed to create Snapshot Path $snapshot_path: $!";
}

sub create_snapshots {

    for my $device (keys %snapshot_filesystems) {
        if ($snapshot_filesystems{$device}->{'mount_type'} eq 'lvm') {
            my $space_needed = $lvs{$device}->{'space_needed'};
            my $snapname = $lvs{$device}->{'snapshotname'};
            print "lvcreate -s -l $space_needed -n $snapname $device\n";
        }
    }
}

sub by_mountpoint_length {
    length($snapshot_filesystems{$a}->{'mountpoint'}) <=> length($snapshot_filesystems{$b}->{'mountpoint'});
}

sub mount_snapshots {
    for my $device (sort by_mountpoint_length keys %snapshot_filesystems) {
        my $mountpoint = $snapshot_filesystems{$device}->{'mountpoint'};
        my $mount_type = $snapshot_filesystems{$device}->{'mount_type'};

        if ($mount_type eq 'lvm') {
        
        my $vg = $lvs{$device}->{'vg'};
        my $snapname = $lvs{$device}->{'snapshotname'};

        print "mount /dev/$vg/$snapname $snapshot_path$mountpoint\n";
        } 
        elsif ($mount_type eq 'bind') {

            print "mount --bind $mountpoint $snapshot_path$mountpoint\n";
        }
        else {
            croak "Unknown mount type $mount_type";
        }
    }
}
        

sub check_free_space {

    for my $device (keys %snapshot_filesystems) {
        my $vg = $lvs{$device}->{'vg'};
        my $lv_pe = $lvs{$device}->{'cur_le'};
        my $pe_needed = ceil($lv_pe * ($snapshot_size_percentage / 100));
        $lvs{$device}->{'space_needed'} = $pe_needed;
        $vgs{$vg}->{'space_needed'} += $pe_needed;
    }

    for my $vg (keys %vgs) {
        my ($free, $needed) = ($vgs{$vg}->{'free_pe'}, $vgs{$vg}->{'space_needed'});
        if ($needed > $free) {
            print "Not enough Physical Extents available in VG $vg. Needed: $needed, Free: $free\n";
            exit 1;
        }
    }
}

sub collect_lvm_information {

    my @vglist = get_volume_group_list();

    for my $vg (@vglist) {
        %{$vgs{$vg}} = get_volume_group_information($vg);
        $vgs{$vg}->{'space_needed'} = 0;

        my %templv = get_logical_volume_information($vg);
        for my $device (keys %templv) {
            $templv{$device}->{'vg'} = $vg;
            $templv{$device}->{'snapshotname'} = $snapshot_lv_prefix . (split /\//, $device)[-1];
        }

        @lvs{keys %templv} = values %templv;
    }
}


sub collect_filesystems {

    my $fs = new Sys::Filesystem;
    my @fs = $fs->filesystems();

    for (@fs) {
        my ($mp, $fstype, $device) = ($fs->mount_point($_), $fs->format($_), $fs->device($_));
        my $lvm_device;
        if ($device =~ m!/mapper/!) {
            $lvm_device = translate_lvm_path($device);
        }
        if (defined $lvm_device && exists $lvs{$lvm_device}) {
            $device = $lvm_device;
            $fs{$device}->{'mount_type'} = 'lvm';
        }
        else {
            $fs{$device}->{'mount_type'} = 'bind';
        }
        $fs{$device}->{'fstype'} = $fstype;
        $fs{$device}->{'mountpoint'} = $mp;
    }
}

sub build_filesystem_list {
    my %snapfs;
    for my $device (keys %fs) {
        my $fstype = $fs{$device}->{'fstype'};
        my $mountpoint = $fs{$device}->{'mountpoint'};

        if (not exists $included_filesystems{$fstype}) {
            #print "Excluding $device - wrong fstype\n";
            next;
        }

        if (exists $excluded_mountpoints{$mountpoint}) {
            #print "Excluding $device - excluded mountpoint\n";
            next;
        }

        if (exists $excluded_volumes{$device}) {
            #print "Excluding $device - excluded volume\n";
            next;
        }

        $snapfs{$device} = $fs{$device};

    }
    return %snapfs;
}
        


sub translate_lvm_path {
#FIXME: Dashes in VG-Names?
#FIXME: LVM-Detection.
       
    my ($path) = @_;

    my $newpath;

    if ($path =~ m!/mapper/!) {
        my ($scratch) = $path =~ m{/dev/mapper/([a-zA-Z0-9_-]+)$};
        croak "Failed to parse LVM path $path" unless defined($scratch);
        my ($vg, $lv) = split /-/, $scratch;
        $lv =~ s/--/-/g;
        $newpath = "/dev/$vg/$lv"; 
    } else {
        my ($vg, $lv) = $path =~ m{/dev/([^/]+)/(.+)$};
        croak "Failed to parse LVM path $path" unless defined($vg) && defined($lv);
        $lv =~ s/-/--/g;

        $newpath = "/dev/mapper/$vg-$lv";

    }

    return $newpath;
}
