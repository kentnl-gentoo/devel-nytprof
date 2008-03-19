#define PERL_NO_GET_CONTEXT		/* we want efficiency */

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "ppport.h"

#include <sys/time.h>
#include <stdio.h>
#ifdef HAS_STDIO_EXT_H
#include <stdio_ext.h>
#else
#warning "Not using stdio_ext.h. Add it to INCLUDE path and recompile with -DHAS_STDIO_EXT_H to use it."
#endif

#ifdef HASFPURGE
#define FPURGE(file) fpurge(file)
#elif defined(HAS_FPURGE)
#define FPURGE(file) _fpurge(file)
#elif defined(HAS__FPURGE)
#define FPURGE(file) __fpurge(file)
#else
#undef FPURGE
#warning "Not using _fpurge() -- There may be a preformance penalty."
#endif

#if !defined(OutCopFILE)
#define OutCopFILE CopFILE
#endif

/* Hash table definitions */
#define MAX_HASH_SIZE 512

typedef struct hash_entry {
	unsigned int id;
	void* next_entry;
	char* key;
} Hash_entry;

typedef struct hash_table {
	Hash_entry** table;
	unsigned int size;
} Hash_table;

static Hash_table hashtable = {NULL, MAX_HASH_SIZE};
/* END Hash table definitions */

static char error[255];

/* defaults */
static char* default_file = "nytprof.out";
static FILE* out;
static FILE* in;
static pid_t last_pid;
static unsigned int bufsiz = BUFSIZ;
static char* out_buffer;
static bool forkok = 0;
static bool usecputime = 0;

/* options and overrides */
static char PROF_output_file[255];
static char READER_input_file[255];
static bool PROF_use_stdout = 0;
static bool READER_use_stdin = 0;

/* time tracking */
static struct tms start_ctime, end_ctime;
#ifdef _HAS_GETTIMEOFDAY
static struct timeval start_time, end_time;
#else
static int (*u2time)(pTHX_ UV *) = 0;
static UV start_utime[2], end_utime[2];
#endif
static unsigned int last_executed_line;
static unsigned int last_executed_file;
static bool firstrun = 1;

/* reader module variables */
static HV* profile;
static unsigned int ticks_per_sec = 1;

/* prototypes */
void lock_file();
void unlock_file();
void print_header();
unsigned int get_file_id(char*);
void output_int(unsigned int);
void DB(pTHX);
void set_option(const char*);
void open_file(bool);
void init_runtime();
void init(pTHX);
bool init_reader(const char*);
void DEBUG_print_stats(pTHX);
IV   getTicksPerSec();
void addline(pTHX_ unsigned int, float, const char*);
HV* process(char*);

/***********************************
 * Devel::NYTProf Functions        *
 ***********************************/

/**
 * Set file lock
 */
void
lock_file() {
	static struct flock lockl = { F_WRLCK, SEEK_SET, 0, 0 };
	fcntl(fileno(out), F_SETLKW, 	&lockl);
	fseek(out, 0, SEEK_END);
}

/**
 * Release file lock
 */
void
unlock_file() {
#ifndef FPURGE
	fflush(out);
#endif
	static struct flock locku = { F_UNLCK, SEEK_SET, 0, 0 };
	fcntl(fileno(out), F_SETLK, 	&locku);
}

/**
 * output file header
 */
void
print_header() {
	unsigned int ticks = 1000000;

	if (forkok) 
		lock_file();

	fputs("# Perl Profile database. Generated by Devel::NYTProf.\n", out);

	if (usecputime) {
		ticks = CLOCKS_PER_SEC;
	}
	fprintf(out, "# CLOCKS: %u\n", ticks);

	if (forkok)
		fflush(out);
		unlock_file();
}

/**
 * An implementation of the djb2 hash function by Dan Bernstein.
 */
unsigned long
hash (char* _str) {
	char* str = _str;
	unsigned long hash = 5381;
	int c;

	while ((c = *str++)) {
		hash = ((hash << 5) + hash) + c; /* hash * 33 + c */
	}
	return hash;
}

/**
 * Fetch/Store on hash table.  entry must always be defined. 
 * hash_op will find hash_entry in the hash table.  
 * hash_entry not in table, insert is false: returns NULL
 * hash_entry not in table, insert is true: inserts hash_entry and returns hash_entry
 * hash_entry in table, insert IGNORED: returns pointer to the actual hash entry
 */
char
hash_op (Hash_entry entry, Hash_entry** retval, bool insert) {
	static int next_fid = 0;
	unsigned long h = hash(entry.key) % hashtable.size;

	Hash_entry* found = hashtable.table[h];
	while(NULL != found) {

		if (0 == strcmp(found->key, entry.key)) {
			*retval = found;
			return 0;
		}

		if(NULL == (Hash_entry*)found->next_entry) {
			if (insert) {
				int sn;

				Hash_entry* e = (Hash_entry*)malloc(sizeof(Hash_entry));
				e->id = next_fid++;
				e->next_entry = NULL;
				sn = strlen(entry.key);
				e->key = (char*)malloc(sizeof(char) * sn + 1);
				e->key[sn] = '\0';
				strncpy(e->key, entry.key, sn);

				*retval = found->next_entry = e;
				return 1;
			} else {
				*retval = NULL;
				return -1;
			}
		}
		found = (Hash_entry*)found->next_entry;
	}

	if (insert) {
		int sn;

		Hash_entry* e = (Hash_entry*)malloc(sizeof(Hash_entry));
		e->id = next_fid++;
		e->next_entry = NULL;
		sn = strlen(entry.key);
		e->key = (char*)malloc(sizeof(char) * sn + 1);
		e->key[sn] = '\0';
		strncpy(e->key, entry.key, sn);

		*retval =	hashtable.table[h] = e;
		return 1;
	}

	retval = NULL;
	return -1;
}

/**
 * Return a unique id number for this file.  Persists across calls.
 */
unsigned int
get_file_id(char* file_name) {

	Hash_entry entry, *found;
	entry.key = file_name;

	if(1 == hash_op(entry, &found, 1)) {
		if (forkok)
			lock_file();

		fputc('@', out);
		output_int(found->id);
		fputs(file_name, out);
		fputc('\n', out);

		if (forkok)
			unlock_file();
	}
	/*else if (
		fprintf(stderr, "Hash access error!\n");
		return 0;
	}*/

	return found->id;
}

/**
 * Output an integer in bytes. That is, output the number in binary, using the
 * least number of bytes possible.  All numbers are positive. Use sign slot as
 * a marker
 */
void output_int(unsigned int i) {

	/* general case. handles all integers */
	if (i < 0x80) { /* < 8 bits */
		fputc( (char)i, out);
	}
	else if (i < 0x4000) { /* < 15 bits */
		fputc( (char)((i >> 8) | 0x80), out);
		fputc( (char)i, out);
	}
	else if (i < 0x200000) { /* < 22 bits */
		fputc( (char)((i >> 16) | 0xC0), out);
		fputc( (char)(i >> 8), out);
		fputc( (char)i, out);
	}
	else if (i < 0x10000000)  { /* 32 bits */
		fputc( (char)((i >> 24) | 0xE0), out);
		fputc( (char)(i >> 16), out);
		fputc( (char)(i >> 8), out);
		fputc( (char)i, out);
	}
	else {	/* need all the bytes. */
		fputc( 0xFF, out);
		fputc( (char)(i >> 24), out);
		fputc( (char)(i >> 16), out);
		fputc( (char)(i >> 8), out);
		fputc( (char)i, out);
	}
}

/**
 * PerlDB implementation. Called before each breakable line
 */
void
DB(pTHX) {
	IV line;
	char *file;
	unsigned int elapsed;
#if (PERL_VERSION < 8) || ((PERL_VERSION == 8) && (PERL_SUBVERSION < 8))
	PERL_CONTEXT *cx; /* up here per ANSI C rules */
#endif

	if (usecputime) {
		times(&end_ctime);
		elapsed = end_ctime.tms_utime - start_ctime.tms_utime
						+ end_ctime.tms_stime - start_ctime.tms_stime;
	} else {
#ifdef _HAS_GETTIMEOFDAY
		gettimeofday(&end_time, NULL);
		elapsed = (end_time.tv_sec - start_time.tv_sec) * 1000000;
		elapsed += end_time.tv_usec - start_time.tv_usec;
#else
		(*u2time)(aTHX_ end_utime);
		if (end_utime[0] < start_utime[0] + 2000) {
				elapsed = (end_utime[0] - start_utime[0]) * 1000000 + 
										end_utime[1] - start_utime[1];
		}
#endif
	}

#if (PERL_VERSION < 8) || ((PERL_VERSION == 8) && (PERL_SUBVERSION < 8))
	cx = cxstack + cxstack_ix;
	file = OutCopFILE(cx->blk_oldcop);
	line = CopLINE(cx->blk_oldcop);
#else
	file = OutCopFILE(PL_curcop);
	line = CopLINE(PL_curcop);
#endif

	/* out should never be NULL, but perl sometimes falls into DB() AFTER
	   it calls _finish() (which is ONLY used in END {...}. Strange!) */
	if (!out)
		return;

	if (!firstrun) { 
		if (forkok) {
#ifdef FPURGE
			if (last_pid != getpid()) { /* handle forks */
				FPURGE(out);
			}
#endif
			lock_file();
		}

		fputc('+', out);
		output_int(last_executed_file);
		output_int(last_executed_line);
		output_int(elapsed);
		/* printf("Profiled line %d in '%s' as %u ticks\n", line, file, elapsed); */

		if (forkok) {
			unlock_file();
			last_pid = getpid();
		}
	} else {
		firstrun = 0;
	}

	last_executed_file = get_file_id(file);
	last_executed_line = line;

	if (usecputime) {
		times(&start_ctime);
	} else {
#ifdef _HAS_GETTIMEOFDAY
		gettimeofday(&start_time, NULL);
#else
		start_utime[2];
		(*u2time)(aTHX_ start_utime);
#endif
	}
}

/**
 * Sets or toggles the option specified by 'option'. 
 */
void
set_option(const char* option) {
	if(0 == strncmp(option, "use_stdout", 10)) {
		printf("# Using standard out for output.\n");
		PROF_use_stdout = 1;
	} else if(0 == strncmp(option, "in=", 3)) {
		strncpy(READER_input_file, &option[3], 500);
		printf("# Using  %s for input.\n", READER_input_file);
	} else if(0 == strncmp(option, "out=", 4)) {
		strncpy(PROF_output_file, &option[4], 500);
		printf("# Using %s for output.\n", PROF_output_file);
	} else if(0 == strncmp(option, "use_stdin", 9)) {
		printf("# Using stanard in for input.\n");
		READER_use_stdin = 1;
	} else if(0 == strncmp(option, "allowfork", 9)) {
		printf("# Fork mode: ENABLED.\n");
		forkok = 1;
	} else if(0 == strncmp(option, "usecputime", 10)) {
		printf("# Using cpu time.\n");
		usecputime = 1;
	} else {
		fprintf(stderr, "Unknown option: %s\n", option);
	}
}

/**
 * Open the output file. This is encapsulated because the code can be reused
 * without the environment parsing overhead after each fork.
 */
void
open_file(bool forked) {

	if (PROF_use_stdout) {										/* output to stdout */
		int fd = dup(STDOUT_FILENO);
		if (-1 == fd) {
			perror("Unable to dup stdout");
		}
		if (forked) { 
			out = fdopen(fd, "wa");
		} else {
			out = fdopen(fd, "w");
		}
	} else if (0 != strlen(PROF_output_file)) {	/* output to user provided file */
		if (forked) { 
			out = fopen(PROF_output_file, "wba");
		} else {
			out = fopen(PROF_output_file, "wb");
		}
	} else {																	/* output to default output file */
		if (forked) { 
			out = fopen(default_file, "wab");
		} else {
			out = fopen(default_file, "wb");
		}
	}
}

/************************************
 * Shared Reader,NYTProf Functions  *
 ************************************/

/**
 * Populate runtime values from environment, the running script or use defaults
 */
void
init_runtime(const char* file) {

	/* Runtime configuration
	   Environment vars have lower priority */
	char* sysenv = getenv("NYTPROF");
	if (NULL != sysenv && strlen(sysenv) > 0) {
		char env[500];
		char* result = NULL;

		strcpy(env, sysenv);
		result = strtok(env, ":");

		if (NULL == result) {
			set_option(env);
		}
		while(result != NULL) {
			set_option(result);
			result = strtok(NULL, ":");
		}
	}

	/* a file name passed to process(...) has the highest priority */
	if (NULL != file) {
		READER_use_stdin = 0;
		PROF_use_stdout = 0;
		strncpy(READER_input_file, file, strlen(file));
		strncpy(PROF_output_file, file, strlen(file));
	}
}

/* Initial setup */
void
init(pTHX) {
	HV* hash = get_hv("DB::sub", 0);
	struct stat outstat;

	/* Save the process id early. We can monitor it to detect forks that affect 
		 output buffering.
		 NOTE: don't fork before calling the xsloader obviously! */
	last_pid = getpid();


	if (hash == NULL) {
		Perl_croak(aTHX_ "Debug symbols not found. Is perl in debug mode?");
	}

	/* create file id mapping hash */
	hashtable.table = (Hash_entry**)malloc(sizeof(Hash_entry*) * hashtable.size);
	memset(hashtable.table, 0, sizeof(Hash_entry*) * hashtable.size);
	
	init_runtime(NULL);

	open_file(0);

	if (out == NULL) {
		Perl_croak(aTHX_ "Failed to open output file\n");
	}

	/* ideal block size for buffering */
 	if (0 == fstat(fileno(out), &outstat)) {
		bufsiz = outstat.st_blksize;
	}
	out_buffer = (char *)malloc(sizeof(char)*bufsiz);
	setvbuf(out, out_buffer, _IOFBF, bufsiz);
	/*printf("stat block size: %d; os block size %d\n", bufsiz, BUFSIZ);*/
	print_header();

	/* seed first run time */
	if (usecputime) {
		times(&start_ctime);
	} else {
#ifdef _HAS_GETTIMEOFDAY
		gettimeofday(&start_time, NULL);
#else
		SV **svp = hv_fetch(PL_modglobal, "Time::U2time", 12, 0);
		if (!svp || !SvIOK(*svp)) Perl_croak(aTHX_ "Time::HiRes is required");
		u2time = INT2PTR(int(*)(pTHX_ UV*), SvIV(*svp));
		(*u2time)(aTHX_ start_utime);
#endif
	}
}

/************************************
 * Devel::NYTProf::Reader Functions *
 ************************************/

/**
 * reader specific runtime initialization
 */
bool
init_reader(const char* file) {

	init_runtime(file);

	if (READER_use_stdin) {										/* output to stdout */
		int fd = dup(STDIN_FILENO);
		if (-1 == fd) {
			perror("Unable to dup stdin");
		}
		in = fdopen(fd, "r");
	} else if (0 != strlen(READER_input_file)) { /* output to user provided file*/
		in = fopen(READER_input_file, "rb");
	} else {																/* output to default output file */
		in = fopen(default_file, "rb");
	}

	if (in == NULL) {
		return 0;
	}
	return 1;
}

/**
 * prints the stats hash in perl syntax ala data::dumper style 
 */
void
DEBUG_print_stats(pTHX) {
	int numkeys = hv_iterinit(profile);
	/* outer vars */
	SV* line_hv_rv;
	char* filename[255];
	I32 name_len;
	/* inner vars */
	SV* cur_av_rv;
	char* linenum[255];
	I32 linenum_len;

	printf("Stored data for %d keys\n", numkeys);

	printf("$hash = {\n");
	while(NULL != (line_hv_rv = hv_iternextsv(profile, filename, &name_len))) {
		HV* line_hv = (HV*)SvRV(line_hv_rv);
		hv_iterinit(line_hv);
		printf ("  '%s' => {\n", *filename);

		while(NULL != (cur_av_rv = hv_iternextsv(line_hv, linenum, &linenum_len))) {
			AV* cur_av = (AV*)SvRV(cur_av_rv);
			int calls = SvIV(*av_fetch(cur_av, 1, 0));
			float time = SvNV(*av_fetch(cur_av, 0, 0));
			SV** evals_hv_ref = av_fetch(cur_av, 2, 0);
			SV* evals_av_ref;

			printf("    '%s' => [ %f, %d", *linenum, time, calls);

			if (NULL != evals_hv_ref) {
				HV* evals_hv = (HV*)SvRV(*evals_hv_ref);
				char* e_linenum[255];

				printf (", {\n");
				while(NULL != (evals_av_ref = hv_iternextsv(evals_hv, e_linenum,
																										&name_len))) {
					AV* evals_av = (AV*)SvRV(evals_av_ref);
					calls = SvIV(*av_fetch(evals_av, 1, 0));
					time = SvNV(*av_fetch(evals_av, 0, 0));

					printf("                              '%s' => [ %f, %d ],\n", 
									*e_linenum, time, calls);
				}
				printf("                          },\n");
			}
 			printf("           ],\n");
		}
		printf("  },\n");
	}
	printf("};\n");
}

/**
 * Save information about the current line.
 * TODO SLOW! Next on the list for a rewrite.
 */
void
addline(pTHX_ unsigned int line, float time, const char* _file) {

	char* file; /* = (char*)malloc(sizeof(char)*strlen(_file) + 1);*/
	int file_len = 0;
	/* used for evals */
	bool eval_mode = 0;
	int eline = 0;
	float etime = 0;
	/* used in files block */
	SV** file_hv_ref;
	HV* file_hv;
	/* used in lines block */
	char line_str[50];
	SV** line_av_ref;
	AV* line_av;

	if (0 != strncmp(_file, "(eval", 5)) {
		file = (char *)_file;
		file_len = strlen(file);
	}
	else {
		/* its an eval! 'line' is _in_ the eval. File and line number in 'file' */
		char* start = strchr(_file, '[');
		char* end = strrchr(_file, ':');
		if (!start || !end) {
			warn("Ignoring invalid filename syntax '%s'\n", _file);
			return;
		}

		eval_mode = 1;
		file = ++start;
		file_len = end - start;

		/* line number in eval block */
		eline = line;

		/* line number in _file_ */
		line = atoi(end + sizeof(char));

		/* time for this line in the eval block */
		etime = time;

		/* execution time for the file line will be added seperately later */
		time = 0;	

		/*printf("File: %s, line: %d, time: %f, eval line: %d, eval time: %f\n",
						file, line, time, eline, etime); */
	}

	/* AutoLoader adds some information to Perl's internal file name that we have
   to remove or else the file path will be borked */
	if (')' == file[file_len - 1]) {
		char* new_end = strstr(file, " (autosplit ");
		file_len = new_end - file;
	}

	file_hv_ref = hv_fetch(profile, file, file_len, 0);
	
	if (NULL == file_hv_ref) {
		file_hv = newHV();
		hv_store(profile, file, file_len, newRV_noinc((SV*)file_hv), 0);
	} else {
		file_hv = (HV*)SvRV(*file_hv_ref);
	}

	sprintf(line_str, "%u", line);
	line_av_ref = hv_fetch(file_hv, line_str, strlen(line_str), 0);

	if (NULL == line_av_ref) {
		int true_calls = (eval_mode)?0:1;

		line_av = newAV();
		av_store(line_av, 0, newSVnv(time));		/* time */
		av_store(line_av, 1, newSViv(true_calls));				/* calls */
		hv_store(file_hv, line_str, strlen(line_str), newRV_noinc((SV*)line_av), 0);
	} else {
		SV** time_sv_p;
		SV** calls_sv_p;

		line_av = (AV*)SvRV(*line_av_ref);
		time_sv_p = av_fetch(line_av, 0, 0);
		sv_setnv(*time_sv_p, time + SvNVX(*time_sv_p));
		calls_sv_p = av_fetch(line_av, 1, 0);

		if (!eval_mode) {
			sv_inc(*calls_sv_p);
		}
	}

	if (eval_mode) {
		SV** eval_hv_ref = av_fetch(line_av, 2, 0);
		HV* eval_hv;
		SV** eval_av_ref;
		AV* eval_av;

		sprintf(line_str, "%d", eline); /* key */

		if (NULL == eval_hv_ref) {
			eval_hv = newHV();
			av_store(line_av, 2, newRV_noinc((SV*)eval_hv));
		} else {
			eval_hv = (HV*)SvRV(*eval_hv_ref);
		}

		eval_av_ref = hv_fetch(eval_hv, line_str, strlen(line_str), 0);

		if (NULL == eval_av_ref) {
			eval_av = newAV(); /* value */
			av_store(eval_av, 0, newSVnv(etime));
			av_store(eval_av, 1, newSViv(1));
			hv_store(eval_hv, line_str, strlen(line_str), newRV_noinc((SV*)eval_av), 
								0);
		} else {
			SV** time_sv_p;
			SV** calls_sv_p;

			eval_av = (AV*)SvRV(*eval_av_ref);
			time_sv_p = av_fetch(eval_av, 0, 0);
			sv_setnv(*time_sv_p, etime + SvIV(*time_sv_p));
			calls_sv_p = av_fetch(eval_av, 1, 0);
			sv_inc(*calls_sv_p);
		}
	}
}

/**
 * Returns the time that the database was generated.
 * TODO Implement this properly. It was borked due to time constraints
 */
IV
getDatabaseTime() {
	return time(NULL);
}

/**
 * Return the clocks per second as parsed by process(). 1 if not set!
 */
IV
getTicksPerSec() {
	return ticks_per_sec;
}

/**
 * Read an integer, up to 4 bytes stored in binary
 */
unsigned int
read_int() {

	static unsigned char d;
	static unsigned int newint;

	d = fgetc(in);
	if (d < 0x80) { /* 7 bits */
		newint = d;
		return newint;
	}
	else if (d < 0xC0) { /* 14 bits */
		newint = d & 0x7F;
		newint <<= 8;
		newint |= (unsigned char)fgetc(in);
		return newint;
	} 
	else if (d < 0xE0) { /* 21 bits */
		newint = d & 0x1F;
		newint <<= 8;
		newint |= (unsigned char)fgetc(in);
		newint <<= 8;
		newint |= (unsigned char)fgetc(in);
		return newint;
	} 
	else if (d < 0xFF) { /* 28 bits */
		newint = d & 0xF;
		newint <<= 8;
		newint |= (unsigned char)fgetc(in);
		newint <<= 8;
		newint |= (unsigned char)fgetc(in);
		newint <<= 8;
		newint |= (unsigned char)fgetc(in);
		return newint;
	} 
	else if (d == 0xFF) { /* 32 bits */
		newint = (unsigned char)fgetc(in);
		newint <<= 8;
		newint |= (unsigned char)fgetc(in);
		newint <<= 8;
		newint |= (unsigned char)fgetc(in);
		newint <<= 8;
		newint |= (unsigned char)fgetc(in);
		return newint;
	} else {
		dTHX;
		Perl_croak(aTHX_ "File format error. Unrecognized marker");
	}
}

/**
 * Process a profile output file and return the results in a hash like
 * { filename => { line_number => [total_calls, total_time], ... }, ... }
 */
HV*
process(char *file) {
	dTHX; 

	unsigned long input_line = 0L;
	unsigned int file_num;
	unsigned int line_num;
	unsigned int elapsed;
	char text[1024];
	char c; /* for while loop */
	AV* file_id_array = newAV();

	if (! init_reader(file)) {
		Perl_croak(aTHX_ "Failed to open input file\n");
	}

	av_extend(file_id_array, 64);  /* grow it up front. */
	profile = newHV(); /* init new profile hash */

	while(EOF != (c = fgetc(in))) {
		input_line++;

		switch (c) {
			case '+':
			{
				SV** file_name_sv;

				file_num = read_int();
				line_num = read_int();
				elapsed = read_int();

				file_name_sv = av_fetch(file_id_array, file_num, 0);
				if (NULL == file_name_sv) {
					sprintf(error, "File id %d not defined in file '%s'", file_num, 
									file);
					Perl_croak(aTHX_ error);
				}

				addline(aTHX_ line_num, (float)elapsed / ticks_per_sec, 
								SvPVX(*file_name_sv));

				/* printf("Profiled line %u in file %u as %us: %s\n", 
								line_num, file_num,  elapsed, SvPVX(*file_name_sv));
				*/
				break;
			}
			case '@':
			{
				int len;
				SV* text_sv;

				file_num = read_int();

				if (NULL == fgets(text, 1024, in)) {
					sprintf(error, "File format error: '%s' in file declaration'", file);
					Perl_croak(aTHX_ error);
				}

				if (av_exists(file_id_array, file_num)) {
					sprintf(error, "File id %d redefined", file_num);
					Perl_croak(aTHX_ error);
				}

				/* trim newline as per file format */
				len = strlen(text);
				text[--len] = '\0';
				text_sv = newSVpv(text, len);
				av_store(file_id_array, file_num, text_sv);
				/* printf("Found file %s as id %u\n", text, file_num); */
				break;
			}
			case '#':
				if (NULL == fgets(text, 1024, in)) {
					sprintf(error, "Error reading '%s' at line %lu", file, input_line);
					Perl_croak(aTHX_ error);
				}

				if (0 == strncmp(text, " CLOCKS: ", 9)) {
					char* end = &text[strlen(text) - 2];

					ticks_per_sec = strtoul(&text[9], &end, 10);
				}

				/* printf ("comment found and ignored: '%s'\n", text); */
				break;

			default:
				sprintf(error, "File format error: '%s', line %lu", file, input_line);
				Perl_croak(aTHX_ error);
		}
	}
	fclose(in);
	/* DEBUG_print_stats(aTHX); */
	return profile;
}

/***********************************
 * Perl XS Code Below Here         *
 ***********************************/

MODULE = Devel::NYTProf		PACKAGE = Devel::NYTProf		
PROTOTYPES: DISABLE

MODULE = Devel::NYTProf		PACKAGE = DB
PROTOTYPES: DISABLE 

void
DB(...)
	CODE:
		DB(aTHX);

void
init()
	CODE:
		init(aTHX);

void
_finish()
	PPCODE:
		{
			if (out) {
				unsigned int elapsed;
				if (usecputime) {
					times(&end_ctime);
					elapsed = end_ctime.tms_utime + end_ctime.tms_stime -
											start_ctime.tms_utime + start_ctime.tms_stime;
				} else {
#ifdef _HAS_GETTIMEOFDAY
					gettimeofday(&end_time, NULL);
					elapsed = (end_time.tv_sec - start_time.tv_sec) * 1000000;
					elapsed += end_time.tv_usec - start_time.tv_usec;
#else
					dTHX;
					(*u2time)(aTHX_ end_utime);
					if (end_utime[0] < start_utime[0] + 2000) {
						elapsed = (end_utime[0] - start_utime[0]) * 1000000 + 
												end_utime[1] - start_utime[1];
					}
#endif
				}

				if (forkok) {
#ifdef FPURGE
					if (last_pid != getpid()) { /* handle forks */
						FPURGE(out);
					}
#endif
					lock_file();
				}

				fputc('+', out);
				output_int(last_executed_file);
				output_int(last_executed_line);
				output_int(elapsed);
				fflush(out);

				if (forkok)
					unlock_file();
			}
		}

MODULE = Devel::NYTProf		PACKAGE = Devel::NYTProf::Reader
PROTOTYPES: DISABLE 

HV*
process(file=NULL)
	char *file;

IV
getDatabaseTime()

IV
getTicksPerSec()
