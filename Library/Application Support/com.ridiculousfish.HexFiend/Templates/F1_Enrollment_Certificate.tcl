include SBP_common.tcl

set puf_key_length 96

if { [len] == 1548 } {
    set puf_key_length 64
}

requires 0 "1E 5C 00 B1"
hex 4 "Magic BlueSeas (A55E00B1)"
hex 4 "Flags"
section "Serial Info" {
    hex 8 "Raw Value"
}
section "Serial Number" {
    serial_number
}
hex $puf_key_length "ECC Public Key"
hex 48 "Nonce"
hex 888 "Activation Code"
signature
