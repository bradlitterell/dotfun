include SBP_common.tcl



section "First Root Directory" {
    set entries_1 [dir_of_dir]
}

goto 0x0200

section "Second Root Directory" {
    set entries_2 [dir_of_dir]
}


goto [lindex $entries_1 0]

section "Directory 1" {
    set images_1 [dir_of_images]
}

goto [lindex $entries_1 1]

section "Directory 2" {
    set images_2 [dir_of_images]
}


section "Images" {
    foreach image_info $images_1 {
	goto [lindex $image_info 1]
	section [lindex $image_info 0] {
	    single_image
	}
	goto [lindex $image_info 2]
	section [lindex $image_info 0] {
	   single_image
	}
    }
}
