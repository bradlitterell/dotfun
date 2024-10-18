little_endian

hex 1 "Version"
set num_keys [uint8 "Number of Keys"]
hex 2 "Padding"

set offsets [list]

section "Key Index" {

    for {set i 0} {$i < $num_keys} {incr i} {
        section $i {
            set val [uint16 "offset (32 bit word)"]
            lappend offsets  [expr $val * 4]
        }
     }
}


section "Keys" {
    set i 0
    foreach offset $offsets {
        goto $offset
        section $i {
            set key_length [uint32 "Key Length"]
        }
        incr i
    }
}
