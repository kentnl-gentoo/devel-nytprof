# Profile data generated by Devel::NYTProf::Reader
# More information at http://metacpan.org/release/Devel-NYTProf/
# Format: time,calls,time/call,code
0,0,0,# test using enable_profile() to write multiple profile files
0,0,0,
0,1,0,my $file_b = "nytprof-test51-b.out";
0,1,0,my $file_c = "nytprof-test51-c.out";
0,1,0,unlink $file_b, $file_c;
0,0,0,
0,1,0,sub sub1 { 1 }
0,0,0,sub sub2 { 1 }
0,0,0,sub sub3 { 1 }
0,0,0,sub sub4 { 1 }
0,0,0,sub sub5 { 1 }
0,0,0,sub sub6 { 1 }
0,0,0,sub sub7 { 1 }
0,0,0,sub sub8 { 1 }
0,0,0,
0,1,0,sub1(); # profiled
0,0,0,
0,0,0,DB::disable_profile(); # also tests that sub1() call timing has completed
0,0,0,
0,0,0,sub2(); # not profiled
0,0,0,
0,0,0,# switch to new file and (re)enable profiling
0,0,0,# the new file includes accumulated fid and subs-called data
0,0,0,DB::enable_profile($file_b);
0,0,0,
0,0,0,sub3(); # profiled
0,0,0,
0,0,0,DB::finish_profile();
0,0,0,die "$file_b should exist" unless -s $file_b;
0,0,0,
0,0,0,sub4(); # not profiled
0,0,0,
0,0,0,# enable to new file
0,0,0,DB::enable_profile($file_c);
0,0,0,
0,0,0,sub5(); # profiled but file will be overwritten by enable_profile() below
0,0,0,
0,0,0,DB::finish_profile();
0,0,0,
0,0,0,sub6(); # not profiled
0,0,0,
0,0,0,DB::enable_profile(); # enable to current file
0,0,0,
0,0,0,sub7(); # profiled
0,0,0,
0,0,0,DB::finish_profile();
0,0,0,
0,0,0,# This can be removed once we have a better test harness
0,0,0,-f $_ or die "$_ should exist" for ($file_b, $file_c);
0,0,0,
0,0,0,# TODO should test for enable/disable within subs
