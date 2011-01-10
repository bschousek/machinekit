# twopass.tcl:
#
# This file is sourced by haltcl when the inifile item HAL:TWOPASS
# is present and it evaluates all inifile HAL:HALFILE items in two passes.
# HALFILE items may be halcmd files (.hal) or .tcl files
#
# pass0:
#       All HAL:HALFILEs are read.
#       loadrt, loadusr commands are combined and executed at the end
#       of pass0 loadrt commands may be invoked multiple times for the
#       same mod_name.  Both the "count=" and "names=" forms for loadrt
#       are supported but are mutually exclusive for each module.
#       addf commands are deferred to pass1
# pass1:
#       All HAL:HALFILES are reread, commands (except the loadrt and
#       loadusr completed commands) are executed and addf commands
#       are executed in order of occurrence.
#
# A few internal procs are useful by HALFILE tcl scripts:
#
# ::tp::passnumber   returns 0 | 1 for the current pass number
# ::tp::no_puts      disable the tcl "puts" command
# ::tp::alter_puts   alters  the tcl "puts" command so that it
#                    reports <pass0> or <pass1>
# ::tp::restore_puts restores the tcl "puts" command
#

#--------------------------------------------------------------------------
# Copyright: 2011
# Author:    Dewey Garrett <dgarrett@panix.com>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
#--------------------------------------------------------------------------

namespace eval ::tp {
  namespace export passnumber
}

set ::TP(combine_addfs) 0 ;# alternate 1 ==> all addfs at end of pass1

#--------------------------------------------------------------------------
proc ::tp::passnumber {} {
  return $::TP(passnumber)
} ;# passnumber

proc ::tp::no_puts {} {
  rename puts orig_puts
  proc puts {args} {}
} ;# no_puts

proc ::tp::alter_puts {} {
  # puts ?-nonewline? ?channelId? string
  rename puts orig_puts
  switch [passnumber] {
  0 { proc puts {args} {
        set args [lreplace $args end end "<pass0> [lindex $args end]"]
        eval orig_puts "$args"
      }
    }
  1 { proc puts {args} {
        set args [lreplace $args end end "<pass1> [lindex $args end]"]
        eval orig_puts "$args"
      }
    }
   default {return -code error "alter_puts: unknown passno <$passno>"}
  }
} ;# alter_puts

proc ::tp::restore_puts {} {
  rename puts {}
  rename orig_puts puts
} ;# restore_puts

#--------------------------------------------------------------------------

proc ::tp::loadusr_substitute {args} {
  set pass [passnumber]
  #puts "loadusr_substitute<$pass> <$args>"
  if {$pass == 0} {
    #puts "loadusr_substitute<$pass> ignored"
  } else {
    eval orig_loadusr $args
  }
} ;# loadusr_substitute

proc ::tp::loadrt_substitute {args} {
  # syntax: loadrt modulename item=value ...
  set parms  [split $args]
  set module [lindex $parms 0]
  set pass   [passnumber]
  #puts "loadrt_substitute<$pass> <$parms>"

  # keep track of loadrt for each module in order to detect
  # unsupportable loadrt calls in pass1. The ct is the number of
  # loadrt calls not the count total module instances
  if ![info exists ::TP($module,$pass,ct)] {
    set ::TP($module,$pass,ct) 1
  } else {
    incr ::TP($module,$pass,ct) 1
  }

  if {[lsearch -exact $::TP(loaded,modules) $module] >= 0} {
    if {$pass == 0} {
      return -code error "loadrt_substitute: <$module> already loaded"
    } else {
      if {$::TP($module,1,ct) > $::TP($module,0,ct)} {
        puts "loadrt_substitute:<$pass> Ignoring loadrt,\
              $module already loaded:"
        puts "                  <loadrt $parms>"
      }
      return
    }
  }
  if {$pass > 0} {
    eval orig_loadrt $parms
    return
  }
  # pass0 only follows ------------------------------------
  if ![info exists ::TP(modules)] {
    lappend ::TP(modules) $module
  } else {
    if {[lsearch -exact $::TP(modules) $module] < 0} {
      lappend ::TP(modules) $module
    }
  }

  set parms   [lreplace $parms 0 0]
  foreach pair $parms {
    set l     [split $pair =]
    set item  [lindex $l 0]
    set value [lindex $l 1]

    if { ("$item" == "count") || ("$item" == "names") } {
      if ![info exists ::TP($module,form)] {
        set ::TP($module,form) $item
      } else {
        if {$::TP($module,form) != "$item"} {
          return -code error \
          "loadrt_substitute: cannot mix count= and names= forms\
          (module=$module, first used form=$::TP($module,form)"
        }
      }
    }

    switch "$item" {
      count {
              if ![info exists ::TP($module,count)] {
                set ::TP($module,count) $value
              } else {
                incr ::TP($module,count) $value
              }
            }
      names {
              if ![info exists ::TP($module,names)] {
                set ::TP($module,names) $value
              } else {
                set ::TP($module,names) "$::TP($module,names),$value"
              }
            }
     default {
               if ![info exists ::TP($module,other)] {
                 set ::TP($module,other) $pair
               } else {
                 set ::TP($module,other) "$::TP($module,other) $pair"
               }
             }
    }
  } ;# foreach pair
} ;# loadrt_substitute

proc ::tp::addf_substitute {args} {
  # syntax: addf func thread position
  set pass [passnumber]
  if {$pass == 0} {
    lappend ::TP(addf) $args
    #puts "addf_substitute:<$pass> Deferring <$args>"
  } else {
    #puts "addf_substitute:<$pass> Ignoring <$args>"
  }
} ;# addf_substitute

proc ::tp::hide_cmds {} {
  set ::TP(cmds) [hal --commands]
  set ::TP(nochange,cmds) {addf loadrt loadusr source}

  rename loadusr            orig_loadusr
  rename loadusr_substitute loadusr
  rename loadrt             orig_loadrt
  rename loadrt_substitute  loadrt
  rename addf               orig_addf
  rename addf_substitute    addf

  foreach cmd $::TP(cmds) {
    if {[lsearch -exact $::TP(nochange,cmds) $cmd] >= 0} continue
    rename $cmd orig_$cmd
    #puts "hide_cmds: renamed $cmd"
    #proc $cmd {args} [subst {puts "DUMMY $cmd <\$args>"}]
    proc $cmd {args} return
  }
} ;# hide_cmds

proc ::tp::unhide_cmds {} {
  foreach cmd $::TP(cmds) {
    if {[lsearch -exact $::TP(nochange,cmds) $cmd] >= 0} continue
    rename $cmd {}
    rename orig_$cmd $cmd
  }
  if {!$::TP(combine_addfs)} {
    # execute addf in place
    rename addf addf_done
    rename orig_addf addf
  }
} ;# unhide_cmds

proc ::tp::pass0 {} {
  if [info exists ::TP(passnumber)] {
    return -code error "pass0: unexpected passnumber <$::TP(passnumber)>"
  }
  set ::TP(passnumber) 0
  prep_the_files
  set ::TP(loaded,modules) ""
  hide_cmds
    source_the_files
    load_the_modules
  unhide_cmds
  #puts "pass0:END"
} ;# pass0

proc ::tp::prep_the_files {} {
  set passno [passnumber]
  if {$passno == 0} {
    # first convert if necessary
    foreach f $::HAL(HALFILE) {
      set suffix [filesuffix $f]
      switch -exact $suffix {
        tcl {lappend ::TP(runfiles) $f}
        hal {set ::TP($f,tmp) /tmp/[file tail $f].tmp
             hal_to_tcl $f $::TP($f,tmp)
             lappend ::TP(runfiles) $::TP($f,tmp)
        }
        default {return -code error \
                "source_the_files:unknown file type <$suffix>"}
      }
    }
  }
} ;# prep_the_files

proc ::tp::hal_to_tcl {ifile ofile} {
  # When hal files are specified with HAL:HALFILE,
  # try to make them work (preferred way is use tcl files).
  # This could probably be done with one regularexpression

  # Some hal commands conflict with tcl commands.
  # Converting a standard hal file here, so a warning is issued
  # if the possible use of one of these commands is detected.
  # Doubtful these are used much in .hal files to configure.
  # I couldn't find any usage examples.

  set ::TP(conflictwords) {list gets}
  # in a .tcl file, use "hal list" and "hal gets" instead

  set fdin  [open $ifile r]
  set fdout [open $ofile w]
  set lno 0
  while 1 {
    if [eof $fdin] break
    incr lno
    set theline [gets $fdin]
    set line [string trim $theline]
    if {"$line" == ""} continue
    if {[string first # $line] == 0} continue
    foreach suspect $::TP(conflictwords) {
      if {   ([string first "$suspect "  $line] == 0)
          || ([string first " $suspect " $line] >= 0)
        } {
         puts "hal_to_tcl:WARNING in file $ifile, line $lno: \"$suspect\"\
              conflicts with tcl usage"
         puts "$lno:<$theline>"
      }
    }
    set idx 0
    set new $line
    set altered 0
    while {$idx >= 0} {
      set l [string first \[ $line $idx]
      if {$l < 0} break
      set r [string first \] $line $idx]
      if {$r < 0} break
      if {!$altered} {
        set altered 1
        set new ""
      }
      set new "${new}[string range $line $idx [expr $l -1]]"
      set new "${new}\$::[string range $line [expr $l+1] [expr $r-1]]\("
      set s [string first " " $line $r]
      if {$s <0} {
        set new "${new}[string range $line [expr $r + 1] end]\)"
        break
      } else {
        set new "${new}[string range $line [expr $r + 1] [expr -1 + $s]]\) "
      }
      set idx [expr $s + 1]
    }
    if {$altered} {
      puts $fdout $new
    } else {
      puts $fdout $line
    }
  }
  close $fdin
  close $fdout
  return $ofile
} ;# hal_to_tcl

proc ::tp::source_the_files {} {
  foreach f $::TP(runfiles) {
    #puts "source_the_files<[passnumber]> sourcing <$f>"
    source $f
  }
} ;# source_the_files

proc ::tp::filesuffix {f} {
  set dot [string last . $f]
  if {$dot < 0} {return -code error "filesuffix: no suffix <$f>"}
  return [string range $f [expr 1 + $dot ] end]
} ;# filesuffix

proc ::tp::load_the_modules {} {
  #puts "load_the_modules: <$::TP(modules)>"
  foreach m $::TP(modules) {
    set cmd "orig_loadrt $m" ;# this is the real loadrt
    if [info exists ::TP($m,count)] {
      set cmd "$cmd count=$::TP($m,count)"
    } elseif [info exists ::TP($m,names)] {
      set cmd "$cmd names=$::TP($m,names)"
    }
    if [info exists ::TP($m,other)] {
      set cmd "$cmd $::TP($m,other)"
    }
    #puts cmd=$cmd
    eval $cmd
  }
  set ::TP(loaded,modules) $::TP(modules)
  set ::TP(modules) ""
  #puts "load_the_modules:loaded,modules=$::TP(loaded,modules)"
} ;# load_the_modules

proc ::tp::addf_the_funcs {} {
  foreach args $::TP(addf) {
    eval orig_addf $args
  }
} ;# addf_the_funcs

proc ::tp::pass1 {} {
  incr ::TP(passnumber)
  source_the_files
  if {$::TP(combine_addfs)} {
    # execute all addf's at end of pass1
    addf_the_funcs
  }
  foreach name [array names ::TP *,tmp] {
    #puts "pass1: deleting $::TP($name)"
    file delete $::TP($name)
  }
  #puts "pass1:END"
} ;# pass1

::tp::pass0
::tp::pass1
