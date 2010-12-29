#
# Copyright (c) 2010 Michael Smith. All rights reserved.
# 
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#	  notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#	  notice, this list of conditions and the following disclaimer in the
#	  documentation and/or other materials provided with the distribution.
# 
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.	IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.
#

#
# Build an Arduino sketch.
#

################################################################################
# Config options
#
# The Makefile calling us must specify BOARD
#
HARDWARE		?=	arduino
ifeq ($(BOARD),)
$(error ERROR: must set BOARD before including this file)
endif

################################################################################
# Paths
#

#
# Save the system type for later use.
#
SYSTYPE			:=	$(shell uname)

#
# Locate the sketch sources based on the initial Makefile's path
#
SRCROOT			:=	$(realpath $(dir $(firstword $(MAKEFILE_LIST))))

#
# We need to know the location of the sketchbook. For now, assume that it's
# the parent of the source directory.
#
SKETCHBOOK		:=	$(shell cd $(SRCROOT)/.. && pwd)

#
# Work out the sketch name from the name of the source directory.
#
SKETCH			:=	$(lastword $(subst /, ,$(SRCROOT)))

#
# Work out where we are going to be building things
#
TMPDIR			?=	/tmp
BUILDROOT		:=	$(abspath $(TMPDIR)/$(SKETCH).build)

#
# Prefer the compiler bundled with Arduino on e.g. Mac OS.
#

#
# Find Arduino, if not explicitly specified
#
ifeq ($(ARDUINO),)

  #
  # List locations that might be valid ARDUINO settings
  #
  ifeq ($(SYSTYPE),Darwin)
    # use Spotlight to find Arduino.app
    ARDUINO_QUERY	=	'kMDItemKind == Application && kMDItemDisplayName == Arduino.app'
    ARDUINOS		:=	$(addsuffix /Contents/Resources/Java,$(shell mdfind -literal $(ARDUINO_QUERY)))
    ifeq ($(ARDUINOS),)
      $(error ERROR: Spotlight cannot find Arduino on your system.)
    endif
    # use the compiler that comes with Arduino
    TOOLPATH		:=	$(ARDUINOS)/hardware/tools/avr/bin
  endif

  ifeq ($(SYSTYPE),Linux)
    ARDUINO_SEARCHPATH	=	/usr/share/arduino /usr/local/share/arduino
    ARDUINOS		:=	$(wildcard $(ARDUINO_SEARCHPATH))
    TOOLPATH		:=	$(subst :, ,$(PATH))
  endif

  #
  # Pick the first option if more than one candidate is found.
  #
  # XXX this is bad if any of the paths (c:\Program Files\ anyone?) has a space in its name...
  #
  ARDUINO		:=	$(firstword $(ARDUINOS))
  ifeq ($(ARDUINO),)
    $(error ERROR: Cannot find Arduino on this system, please specify on the commandline with ARDUINO=<path>)
  endif

  ifneq ($(words $(ARDUINOS)),1)
    $(warning WARNING: More than one copy of Arduino was found, using $(ARDUINO))
  endif

endif

################################################################################
# Tools
#

#
# XXX should we be using tools from the Arduino distribution?
#
FIND_TOOL		=	$(firstword $(wildcard $(addsuffix /$(1),$(TOOLPATH))))
CXX			=	$(call FIND_TOOL,avr-g++)
CC			=	$(call FIND_TOOL,avr-gcc)
AS			=	$(call FIND_TOOL,avr-gcc)
AR			=	$(call FIND_TOOL,avr-ar)
LD			=	$(call FIND_TOOL,avr-gcc)
OBJCOPY			=	$(call FIND_TOOL,avr-objcopy)
ifeq ($(CXX),)
$(error ERROR: cannot find the compiler tools anywhere on the path $(TOOLPATH))
endif

#
# Tool options
#
DEFINES			=	-DF_CPU=$(F_CPU) -DARDUINO=$(ARDUINO_VERS)
OPTFLAGS		=	-Os

# XXX warning options TBD
CXXOPTS			= 	-mcall-prologues -ffunction-sections -fdata-sections -fno-exceptions
COPTS			=	-mcall-prologues -ffunction-sections -fdata-sections
ASOPTS			=	-assembler-with-cpp 

CXXFLAGS		=	-g -mmcu=$(MCU) $(DEFINES) $(OPTFLAGS) $(CXXOPTS)
CFLAGS			=	-g -mmcu=$(MCU) $(DEFINES) $(OPTFLAGS) $(COPTS)
ASFLAGS			=	-g -mmcu=$(MCU) $(DEFINES) $(ASOPTS)
LDFLAGS			=	-g -mmcu=$(MCU) $(OPTFLAGS) -Wl,--gc-sections

LIBS			=	-lm

SRCSUFFIXES		=	*.cpp *.c *.S

ifeq ($(VERBOSE),)
v			=	@
else
v			=
endif


################################################################################
# Sketch
#

# Sketch source files
SKETCHPDESRCS		:=	$(wildcard $(SRCROOT)/*.pde)
SKETCHSRCS		:=	$(wildcard $(addprefix $(SRCROOT)/,$(SRCSUFFIXES)))
SKETCHPDE		:=	$(wildcard $(SRCROOT)/$(SKETCH).pde)
SKETCHCPP		:=	$(BUILDROOT)/$(SKETCH).cpp

# Sketch object files
SKETCHOBJS		:=	$(subst $(SRCROOT),$(BUILDROOT),$(SKETCHSRCS)) $(SKETCHCPP)
SKETCHOBJS		:=	$(addsuffix .o,$(basename $(SKETCHOBJS)))

# List of input files to the sketch.cpp file in the order they should
# be appended to create it
SKETCHCPP_SRC		:=	$(SKETCHPDE) $(sort $(filter-out $(SKETCHPDE),$(SKETCHPDESRCS)))

################################################################################
# Libraries
#
# Pick libraries to add to the include path and to link with based on
# #include directives in the sketchfiles.
#
# For example:
#
#   #include <Foo.h>
#
# implies that there might be a Foo library.
#
# Note that the # and $ require special treatment to avoid upsetting
# make.
#
SEXPR			=	's/^[[:space:]]*\#include[[:space:]][<\"]([^>\"./]+).*$$/\1/p'
LIBTOKENS		:=	$(sort $(shell cat $(SKETCHPDESRCS) $(SKETCHSRCS) | sed -nEe $(SEXPR)))

#
# Find sketchbook libraries referenced by the sketch.
#
# Include paths for sketch libraries 
#
SKETCHLIBS		:=	$(wildcard $(addprefix $(SKETCHBOOK)/libraries/,$(LIBTOKENS)))
SKETCHLIBNAMES		:=	$(notdir $(SKETCHLIBS))
SKETCHLIBSRCDIRS	:=	$(SKETCHLIBS) $(addsuffix /utility,$(SKETCHLIBS))
SKETCHLIBSRCS		:=	$(wildcard $(foreach suffix,$(SRCSUFFIXES),$(addsuffix /$(suffix),$(SKETCHLIBSRCDIRS))))
SKETCHLIBOBJS		:=	$(addsuffix .o,$(basename $(subst $(SKETCHBOOK),$(BUILDROOT),$(SKETCHLIBSRCS))))
SKETCHLIBINCLUDES	:=	$(addprefix -I,$(SKETCHLIBS))

#
# Find Arduino libraries referenced by the sketch.  Exclude any that
# are overloaded by versions in the sketchbook.
#
ARDUINOLIBS		:=	$(wildcard $(addprefix $(ARDUINO)/libraries/,$(filter-out $(SKETCHLIBNAMES),$(LIBTOKENS))))
ARDUINOLIBNAMES		:=	$(notdir $(ARDUINOLIBS))
ARDUINOLIBSRCDIRS	:=	$(ARDUINOLIBS) $(addsuffix /utility,$(ARDUINOLIBS))
ARDUINOLIBSRCS		:=	$(wildcard $(foreach suffix,$(SRCSUFFIXES),$(addsuffix /$(suffix),$(ARDUINOLIBSRCDIRS))))
ARDUINOLIBOBJS		:=	$(addsuffix .o,$(basename $(subst $(ARDUINO),$(BUILDROOT),$(ARDUINOLIBSRCS))))
ARDUINOLIBINCLUDES	:=	$(addprefix -I,$(ARDUINOLIBS))

# Library object files
LIBOBJS			:=	$(SKETCHLIBOBJS) $(ARDUINOLIBOBJS)

################################################################################
# *duino core
#

# Pull the Arduino version from the revisions.txt file
#
# XXX can we count on this?  If not, what?
ARDUINO_VERS		:=	$(shell expr `head -1 $(ARDUINO)/revisions.txt | cut -d ' ' -f 2`)

# Find the hardware directory to use
HARDWARE_DIR		:=	$(firstword $(wildcard $(SKETCHBOOK)/hardware/$(HARDWARE) \
							$(ARDUINO)/hardware/$(HARDWARE)))
ifeq ($(HARDWARE_DIR),)
$(error ERROR: hardware directory for $(HARDWARE) not found
endif

# Find the boards.txt that we are using
BOARDFILE		:=	$(wildcard $(HARDWARE_DIR)/boards.txt)
ifeq ($(BOARDFILE),)
$(error ERROR: could not locate boards.txt for hardware $(HARDWARE)
endif

# Extract needed build parameters from the boardfile
MCU			:=	$(shell grep $(BOARD).build.mcu $(BOARDFILE) | cut -d = -f 2)
F_CPU			:=	$(shell grep $(BOARD).build.f_cpu $(BOARDFILE) | cut -d = -f 2)
HARDWARE_CORE		:=	$(shell grep $(BOARD).build.core $(BOARDFILE) | cut -d = -f 2)
ifeq ($(MCU),)
$(error ERROR: Could not locate board $(BOARD) in $(BOARDFILE)
endif

# Hardware source files
CORESRC_DIR		=	$(HARDWARE_DIR)/cores/$(HARDWARE_CORE)
CORESRC_PATTERNS	=	$(foreach suffix,/*.cpp /*.c /*.S,$(addsuffix $(suffix),$(CORESRC_DIR)))
CORESRCS		:=	$(wildcard $(CORESRC_PATTERNS))

# Include spec for core includes
COREINCLUDES		=	-I$(CORESRC_DIR)

# Hardware object files
CORELIBOBJS		:=	$(subst $(CORESRC_DIR),$(BUILDROOT)/$(HARDWARE),$(CORESRCS))
CORELIBOBJS		:=	$(addsuffix .o,$(basename $(CORELIBOBJS)))

################################################################################
# Built products
#

# The ELF file
SKETCHELF		=	$(BUILDROOT)/$(SKETCH).elf

# HEX file
SKETCHHEX		=	$(BUILDROOT)/$(SKETCH).hex

# EEP file
SKETCHEEP		=	$(BUILDROOT)/$(SKETCH).eep

# The core library
CORELIB			=	$(BUILDROOT)/$(HARDWARE)/core.a

################################################################################
# Targets
#

all:	$(SKETCHELF) $(SKETCHEEP) $(SKETCHHEX)

upload:

clean:
	@rm -fr $(BUILDROOT)

################################################################################
# Rules
#

# common header for rules, prints what is being built
define RULEHDR
	@echo %% $(subst $(BUILDROOT)/,,$@)
	@mkdir -p $(dir $@)
endef

# Link the final object
$(SKETCHELF):	$(SKETCHOBJS) $(LIBOBJS) $(CORELIB)
	$(RULEHDR)
	$(v)$(LD) $(LDFLAGS) -o $@ $^ $(LIBS)

# Create the hex file
$(SKETCHHEX):	$(SKETCHELF)
	$(RULEHDR)
	$(v)$(OBJCOPY) -O ihex -R .eeprom $< $@

# Create the eep file
$(SKETCHEEP):	$(SKETCHELF)
	$(RULEHDR)
	$(v)$(OBJCOPY) -O ihex -j.eeprom --set-section-flags=.eeprom=alloc,load --no-change-warnings --change-section-lma .eeprom=0 $< $@

# Make the buildroot
$(BUILDROOT):
	@mkdir -p $(BUILDROOT)

#
# Build sketch objects
#
SKETCH_INCLUDES	=	$(SKETCHLIBINCLUDES) $(ARDUINOLIBINCLUDES) $(COREINCLUDES)

$(BUILDROOT)/%.o: $(BUILDROOT)/%.cpp
	$(RULEHDR)
	$(v)$(CXX) $(CXXFLAGS) -c -o $@ $< -I$(SRCROOT) $(SKETCH_INCLUDES)

$(BUILDROOT)/%.o: $(SRCROOT)/%.cpp
	$(RULEHDR)
	$(v)$(CXX) $(CXXFLAGS) -c -o $@ $< $(SKETCH_INCLUDES)

$(BUILDROOT)/%.o: $(SRCROOT)/%.c
	$(RULEHDR)
	$(v)$(CC) $(CFLAGS) -c -o $@ $< $(SKETCH_INCLUDES)

$(BUILDROOT)/%.o: $(SRCROOT)/%.S
	$(RULEHDR)
	$(v)$(AS) $(ASFLAGS) -c -o $@ $< $(SKETCH_INCLUDES)

#
# Build library objects from sources in the sketchbook
#
SLIB_INCLUDES	=	-I$(dir $<)/utility $(SKETCHLIBINCLUDES) $(ARDUINOLIBINCLUDES) $(COREINCLUDES)

$(BUILDROOT)/libraries/%.o: $(SKETCHBOOK)/libraries/%.cpp
	$(RULEHDR)
	$(v)$(CXX) $(CXXFLAGS) -c -o $@ $< $(SLIB_INCLUDES)

$(BUILDROOT)/libraries/%.o: $(SKETCHBOOK)/libraries/%.c
	$(RULEHDR)
	$(v)$(CC) $(CFLAGS) -c -o $@ $< $(SLIB_INCLUDES)

$(BUILDROOT)/libraries/%.o: $(SKETCHBOOK)/libraries/%.S
	$(RULEHDR)
	$(v)$(AS) $(ASFLAGS) -c -o $@ $< $(SLIB_INCLUDES)

#
# Build library objects from Ardiuno library sources
#
ALIB_INCLUDES	=	-I$(dir $<)/utility $(ARDUINOLIBINCLUDES) $(COREINCLUDES)

$(BUILDROOT)/libraries/%.o: $(ARDUINO)/libraries/%.cpp
	$(RULEHDR)
	$(v)$(CXX) $(CXXFLAGS) -c -o $@ $< $(ALIB_INCLUDES)

$(BUILDROOT)/libraries/%.o: $(ARDUINO)/libraries/%.c
	$(RULEHDR)
	$(v)$(CC) $(CFLAGS) -c -o $@ $< $(ALIB_INCLUDES)

$(BUILDROOT)/libraries/%.o: $(ARDUINO)/libraries/%.S
	$(RULEHDR)
	$(v)$(AS) $(ASFLAGS) -c -o $@ $< $(ALIB_INCLUDES)

#
# Build objects from the hardware core
#
$(BUILDROOT)/$(HARDWARE)/%.o: $(CORESRC_DIR)/%.cpp
	$(RULEHDR)
	$(v)$(CXX) $(CXXFLAGS) -c -o $@ $< -I$(CORESRC_DIR)

$(BUILDROOT)/$(HARDWARE)/%.o: $(CORESRC_DIR)/%.c
	@mkdir -p $(dir $@)
	$(v)$(CC) $(CFLAGS) -c -o $@ $< -I$(CORESRC_DIR)

$(BUILDROOT)/$(HARDWARE)/%.o: $(CORESRC_DIR)/%.S
	$(RULEHDR)
	$(v)$(AS) $(ASFLAGS) -c -o $@ $< -I$(CORESRC_DIR)

#
# Build the core library
#
$(CORELIB): $(CORELIBOBJS)
	$(RULEHDR)
	$(v)$(AR) -rcs $@ $^

#
# Build the sketch.cpp file
#
# This process strives to be as faithful to the Arduino implementation as
# possible.  Conceptually, the process is as follows:
#
# * All of the .pde files are concatenated, starting with the file named 
#   for the sketch and followed by the others in alphabetical order.
# * An insertion point is created in the concatenated file at
#   the first statement that isn't a preprocessor directive or comment.
# * An include of "WProgram.h" is inserted at the insertion point.
# * The file following the insertion point is scanned for function definitions
#   and prototypes for these functions are inserted at the insertion point.
#
# In addition, we add #line directives wherever the originating file changes
# to help backtrack from compiler messages and in the debugger.
#
$(SKETCHCPP):	$(SKETCHCPP_SRC) $(BUILDROOT)
	$(RULEHDR)
	$(v)awk -v mode=header '$(SKETCH_SPLITTER)'   $(SKETCHCPP_SRC) >  $@
	$(v)echo "#line 1 \"autogenerated\""                           >> $@
	$(v)echo "#include \"WProgram.h\""                             >> $@
	$(v)awk                '$(SKETCH_PROTOTYPER)' $(SKETCHCPP_SRC) >> $@
	$(v)awk -v mode=body   '$(SKETCH_SPLITTER)'   $(SKETCHCPP_SRC) >> $@

# delete the sketch.cpp file if a processing error occurs
.DELETE_ON_ERROR: $(SKETCHCPP)

#
# The sketch splitter is an awk script used to split off the
# header and body of the concatenated .pde files.  It also
# inserts #line directives to help in backtracking from compiler
# and debugger messages to the original source file.
#
# Note that # and $ require special treatment here to avoid upsetting
# make.
#
define SKETCH_SPLITTER
  BEGIN { 							\
    scanning = 1; 						\
    printing = (mode ~ "header") ? 1 : 0;			\
  }								\
  { toggles = 1 }						\
  (FNR == 1) && printing { 					\
    printf "#line %d \"%s\"\n", FNR, FILENAME;			\
  }								\
  /^[[:space:]]*\/\*/,/\*\// { 					\
    toggles = 0;						\
  }								\
  /^[[:space:]]*$$/ || /^[[:space:]]*\/\/.*/ || /^\#.*$$/ { 	\
    toggles = 0;						\
  }								\
  scanning && toggles { 					\
    scanning = 0; 						\
    printing = !printing;					\
    if (printing) { 						\
      printf "#line %d \"%s\"\n", FNR, FILENAME;		\
    }								\
  }								\
  printing
endef

#
# The prototype scanner is an awk script used to generate function
# prototypes from the concantenated .pde files.
#
# Function definitions are expected to follow the form
#
#   <newline><type>[<qualifier>...]<name>([<arguments>]){
#
# with whitespace permitted between the various elements.  The pattern
# is assembled from separate subpatterns to make adjustments easier.
#
# Note that $ requires special treatment here to avoid upsetting make,
# and backslashes are doubled in the partial patterns to satisfy
# escaping rules.
#
define SKETCH_PROTOTYPER
  BEGIN {								\
    RS="{";								\
    type       = "((\\n)|(^))[[:space:]]*[[:alnum:]_]+[[:space:]]+";	\
    qualifiers = "([[:alnum:]_\\*&]+[[:space:]]*)*";			\
    name       = "[[:alnum:]_]+[[:space:]]*";				\
    args       = "\\([[:space:][:alnum:]_,&\\*\\[\\]]*\\)";		\
    bodycuddle = "[[:space:]]*$$";					\
    pattern    = type qualifiers name args bodycuddle;			\
  }									\
  match($$0, pattern) {							\
    proto = substr($$0, RSTART, RLENGTH);				\
    gsub("\n", " ", proto);						\
    printf "%s;\n", proto;						\
  }
endef
