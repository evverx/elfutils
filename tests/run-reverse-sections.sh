#! /bin/sh
# Copyright (C) 2019 Red Hat, Inc.
# This file is part of elfutils.
#
# This file is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# elfutils is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

. $srcdir/test-subr.sh

test_reverse ()
{
  in_file="$1"
  out_file="${in_file}.rev"
  out_file_mmap="${out_file}.mmap"

  testfiles ${in_file}
  tempfiles ${out_file} ${out_file_mmap}

  # Reverse the offsets (the files should still be the same otherwise)
  testrun ${abs_builddir}/elfcopy --reverse-offs ${in_file} ${out_file}
  testrun ${abs_top_builddir}/src/elfcmp ${in_file} ${out_file}
  testrun ${abs_top_builddir}/src/elflint --gnu ${out_file}
  # An in-place nop will likely revert them back
  testrun ${abs_builddir}/elfrdwrnop ${out_file}
  testrun ${abs_top_builddir}/src/elfcmp ${in_file} ${out_file}
  testrun ${abs_top_builddir}/src/elflint --gnu ${out_file}
}

# A collection of random testfiles to test 32/64bit, little/big endian
# and non-ET_REL (with phdrs)/ET_REL (without phdrs).

# 32bit, big endian, rel
test_reverse testfile29

# 64bit, big endian, rel
test_reverse testfile23

# 32bit, little endian, rel
test_reverse testfile9

# 64bit, little endian, rel
test_reverse testfile38

# 32bit, big endian, non-rel
test_reverse testfile26

# 64bit, big endian, non-rel
test_reverse testfile27

# 32bit, little endian, non-rel
test_reverse testfile

# 64bit, little endian, non-rel
# Don't use testfile10. It has section headers in the middle of the file.
# Same for testfile12. It is legal, but not the point of this testcase.
# test_reverse testfile10
test_reverse testfile13

exit 0
