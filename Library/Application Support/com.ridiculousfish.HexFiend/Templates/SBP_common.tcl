little_endian

proc serial_number {} {

    section "Part Number" {
	    hex 1 "Family"
	    hex 1 "Device"
	    hex 1 "Revision"
	}
	hex 1 "Foundry + Fab"
	hex 1 "Year"
	hex 1 "Week"
	hex 2 "Security Group"
	hex 4 "Reserved (Zero)"
	hex 4 "S/N"
}

proc tampers {} {
    for {set i 0 } {$i < 16} {incr i} {
	set dtamper [hex 1]
	entry [ format "Tamper %d" [expr {$i * 2} ]] [expr {$dtamper & 0x7}]
	entry [ format "Tamper %d" [expr {$i * 2 + 1} ]]  [expr {$dtamper >> 4}]
    }
}

proc sig_or_key {name} {
    section $name {
	set save_pos [pos]
	set key_length [uint32 "$name Length"]
	hex $key_length $name
	goto [expr {$save_pos + 4 + 512}]
    }
}

proc signature {} {
    sig_or_key "Signature"
}

proc key {} {
    sig_or_key "Key"
}

proc TBS_SBP_certificate {} {
    requires 0 "A5 5E 00 B1"
    hex 4 "Magic BlueSeas (A55E00B1)"
    hex 4 "Debug Locks"
    hex 1 "Authorizations"
    hex 1 "Key Index (unused)"
    hex 2 "Reserved (Zero)"
    uint32 "Tamper Authorizations (unused)"
    section "Serial Info" {
	hex 8 "Raw Value"
    }
    section "Serial Number" {
	serial_number
    }
    section "Serial Info Mask" {
	hex 8 "Raw Value"
    }
    section "Serial Number Mask" {
        serial_number
    }
    key
}

proc dir_of_dir {} {

    hex 4 "CRC Dir of Dir"
    set directory_1 [uint32 -hex "Directory 1"]
    set directory_2 [uint32 -hex "Directory 2"]
    return [list $directory_1 $directory_2]
}

proc dir_of_images {} {
    hex 4 "CRC Fixed Directory"
    set puf_rom1 [uint32 -hex "PUF ROM 1"]
    set puf_rom2 [uint32 -hex "PUF ROM 2"]
    set images [list]
    lappend images [list "pufr" $puf_rom1 $puf_rom2]
    hex 4 "CRC Variable Directory"

    while 1 {
	set addr1 [uint32 -hex "Addr1"]
	set addr2 [uint32 -hex "Addr2"]
	if {$addr1 == 0xFFFFFFFF} break
	set image_type [ascii 4 "type"]
	lappend images [list $image_type $addr1 $addr2]
    }
    return $images
}

proc single_image {} {
    bytes 1096 "customer certificate"
    bytes 428 "padding"
    bytes 8   "customer magic"
    bytes 516 "customer signature"
    bytes 1096 "signing info"
    bytes 428 "padding"
    bytes 8    "fungible magic"
    bytes 516 "signature"
    set image_size [uint32 "size"]
    uint32 "version"
    ascii 4 "type"
    section "attributes" {
	section "Part Number" {
	    hex 1 "Family"
	    hex 1 "Device"
	    hex 1 "Revision"
	    hex 1 "Alignment"
	}
	section AuthLocation {
	    uint32 -hex "Location"
	}
	hex 24 "padding"
	ascii 32 "description"
    }
    entry "payload" bytes  $image_size
}
