/*
 *  Store and retrieve mechanism.
 *
 *  Copyright (c) 1995-2000, Raphael Manfredi
 *  
 *  You may redistribute only under the same terms as Perl 5, as specified
 *  in the README file that comes with the distribution.
 *
 */

#define PERL_NO_GET_CONTEXT     /* we want efficiency */
#include <EXTERN.h>
#include <perl.h>
#include <XSUB.h>

#ifndef PATCHLEVEL
#include <patchlevel.h>		/* Perl's one, needed since 5.6 */
#endif

#if !defined(PERL_VERSION) || PERL_VERSION < 10 || (PERL_VERSION == 10 && PERL_SUBVERSION < 1)
#define NEED_load_module
#define NEED_vload_module
#define NEED_newCONSTSUB
#define NEED_newSVpvn_flags
#define NEED_newRV_noinc
#include "ppport.h"             /* handle old perls */
#endif

#if 0
#define DEBUGME /* Debug mode, turns assertions on as well */
#define DASSERT /* Assertion mode */
#endif

/*
 * Pre PerlIO time when none of USE_PERLIO and PERLIO_IS_STDIO is defined
 * Provide them with the necessary defines so they can build with pre-5.004.
 */
#ifndef USE_PERLIO
#ifndef PERLIO_IS_STDIO
#define PerlIO FILE
#define PerlIO_read(x,y,z) fread(y,1,z,x)
#define PerlIO_write(x,y,z) fwrite(y,1,z,x)
#define PerlIO_stdoutf printf
#endif	/* PERLIO_IS_STDIO */
#endif	/* USE_PERLIO */

/*
 * Earlier versions of perl might be used, we can't assume they have the latest!
 */

#ifndef HvSHAREKEYS_off
#define HvSHAREKEYS_off(hv)	/* Ignore */
#endif

/* perl <= 5.8.2 needs this */
#ifndef SvIsCOW
# define SvIsCOW(sv) 0
#endif

#ifndef HvRITER_set
#  define HvRITER_set(hv,r)	(HvRITER(hv) = r)
#endif
#ifndef HvEITER_set
#  define HvEITER_set(hv,r)	(HvEITER(hv) = r)
#endif

#ifndef HvRITER_get
#  define HvRITER_get HvRITER
#endif
#ifndef HvEITER_get
#  define HvEITER_get HvEITER
#endif

#ifndef HvPLACEHOLDERS_get
#  define HvPLACEHOLDERS_get HvPLACEHOLDERS
#endif

#ifndef HvTOTALKEYS
#  define HvTOTALKEYS(hv)	HvKEYS(hv)
#endif

#ifdef DEBUGME

#ifndef DASSERT
#define DASSERT
#endif

/*
 * TRACEME() will only output things when the $Storable::DEBUGME is true.
 */

#define TRACEME(x)                                                      \
        STMT_START {                                                    \
                if (SvTRUE(perl_get_sv("Storable::DEBUGME", GV_ADD)))	\
		{ PerlIO_stdoutf x; PerlIO_stdoutf("\n"); }		\
        } STMT_END
#else
#define TRACEME(x)
#endif	/* DEBUGME */

#ifdef DASSERT
#define ASSERT(x,y)                                                     \
        STMT_START {                                                    \
                if (!(x)) {                                             \
                        PerlIO_stdoutf("ASSERT FAILED (\"%s\", line %d): ", \
                                       __FILE__, __LINE__);             \
                        PerlIO_stdoutf y; PerlIO_stdoutf("\n");         \
                }                                                       \
        } STMT_END
#else
#define ASSERT(x,y)
#endif

/*
 * Type markers.
 */

#define C(x) ((char) (x))	/* For markers with dynamic retrieval handling */

#define SX_OBJECT	C(0)	/* Already stored object */
#define SX_LSCALAR	C(1)	/* Scalar (large binary) follows (length, data) */
#define SX_ARRAY	C(2)	/* Array forthcoming (size, item list) */
#define SX_HASH		C(3)	/* Hash forthcoming (size, key/value pair list) */
#define SX_REF		C(4)	/* Reference to object forthcoming */
#define SX_UNDEF	C(5)	/* Undefined scalar */
#define SX_INTEGER	C(6)	/* Integer forthcoming */
#define SX_DOUBLE	C(7)	/* Double forthcoming */
#define SX_BYTE		C(8)	/* (signed) byte forthcoming */
#define SX_NETINT	C(9)	/* Integer in network order forthcoming */
#define SX_SCALAR	C(10)	/* Scalar (binary, small) follows (length, data) */
#define SX_TIED_ARRAY	C(11)	/* Tied array forthcoming */
#define SX_TIED_HASH	C(12)	/* Tied hash forthcoming */
#define SX_TIED_SCALAR	C(13)	/* Tied scalar forthcoming */
#define SX_SV_UNDEF	C(14)	/* Perl's immortal PL_sv_undef */
#define SX_SV_YES	C(15)	/* Perl's immortal PL_sv_yes */
#define SX_SV_NO	C(16)	/* Perl's immortal PL_sv_no */
#define SX_BLESS	C(17)	/* Object is blessed */
#define SX_IX_BLESS	C(18)	/* Object is blessed, classname given by index */
#define SX_HOOK		C(19)	/* Stored via hook, user-defined */
#define SX_OVERLOAD	C(20)	/* Overloaded reference */
#define SX_TIED_KEY	C(21)	/* Tied magic key forthcoming */
#define SX_TIED_IDX	C(22)	/* Tied magic index forthcoming */
#define SX_UTF8STR	C(23)	/* UTF-8 string forthcoming (small) */
#define SX_LUTF8STR	C(24)	/* UTF-8 string forthcoming (large) */
#define SX_FLAG_HASH	C(25)	/* Hash with flags forthcoming (size, flags, key/flags/value triplet list) */
#define SX_CODE         C(26)   /* Code references as perl source code */
#define SX_WEAKREF	C(27)	/* Weak reference to object forthcoming */
#define SX_WEAKOVERLOAD	C(28)	/* Overloaded weak reference */
#define SX_VSTRING	C(29)	/* vstring forthcoming (small) */
#define SX_LVSTRING	C(30)	/* vstring forthcoming (large) */
#define SX_ERROR	C(31)	/* Error */

/*
 * Those are only used to retrieve "old" pre-0.6 binary images.
 */
#define SX_ITEM		'i'		/* An array item introducer */
#define SX_IT_UNDEF	'I'		/* Undefined array item */
#define SX_KEY		'k'		/* A hash key introducer */
#define SX_VALUE	'v'		/* A hash value introducer */
#define SX_VL_UNDEF	'V'		/* Undefined hash value */

/*
 * Those are only used to retrieve "old" pre-0.7 binary images
 */

#define SX_CLASS	'b'		/* Object is blessed, class name length <255 */
#define SX_LG_CLASS	'B'		/* Object is blessed, class name length >255 */
#define SX_STORED	'X'		/* End of object */

/*
 * Limits between short/long length representation.
 */

#define LG_SCALAR	255		/* Large scalar length limit */
#define LG_BLESS	127		/* Large classname bless limit */

/*
 * Operation types
 */

/*
 * At store time:
 * A ptr table records the objects which have already been stored.
 * Those are referred to as SX_OBJECT in the file, and their "tag" (i.e.
 * an arbitrary sequence number) is used to identify them.
 *
 * At retrieve time:
 * An array table records the objects which have already been retrieved,
 * as seen by the tag determined by counting the objects themselves. The
 * reference to that retrieved object is kept in the table, and is returned
 * when an SX_OBJECT is found bearing that same tag.
 *
 * The same processing is used to record "classname" for blessed objects:
 * indexing by a hash at store time, and via an array at retrieve time.
 */

/*
 * The following "thread-safe" related defines were contributed by
 * Murray Nesbitt <murray@activestate.com> and integrated by RAM, who
 * only renamed things a little bit to ensure consistency with surrounding
 * code.	-- RAM, 14/09/1999
 *
 * The original patch suffered from the fact that the stcxt_t structure
 * was global.  Murray tried to minimize the impact on the code as much as
 * possible.
 *
 * Starting with 0.7, Storable can be re-entrant, via the STORABLE_xxx hooks
 * on objects.  Therefore, the notion of context needs to be generalized,
 * threading or not.
 */

#define MY_VERSION "Storable(" XS_VERSION ")"


/*
 * Conditional UTF8 support.
 *
 */
#ifdef SvUTF8_on
#define WRITE_UTF8STR(pv, len)	WRITE_PV_WITH_LEN_AND_TYPE(pv, len, SX_UTF8STR)
#define HAS_UTF8_SCALARS
#ifdef HeKUTF8
#define HAS_UTF8_HASHES
#define HAS_UTF8_ALL
#else
/* 5.6 perl has utf8 scalars but not hashes */
#endif
#else
#define SvUTF8(sv) 0
#define WRITE_UTF8STR(pv, len) CROAK(("panic: storing UTF8 in non-UTF8 perl"))
#endif
#ifndef HAS_UTF8_ALL
#define UTF8_CROAK() CROAK(("Cannot retrieve UTF8 data in non-UTF8 perl"))
#endif
#ifndef SvWEAKREF
#define WEAKREF_CROAK() CROAK(("Cannot retrieve weak references in this perl"))
#endif
#ifndef SvVOK
#define VSTRING_CROAK() CROAK(("Cannot retrieve vstring in this perl"))
#endif

#ifdef HvPLACEHOLDERS
#define HAS_RESTRICTED_HASHES
#else
#define HVhek_PLACEHOLD	0x200
#endif

#ifdef HvHASKFLAGS
#define HAS_HASH_KEY_FLAGS
#endif

#ifndef SvTRUE_NN
#define SvTRUE_NN SvTRUE
#endif

#ifndef sv_derived_from_sv
#define sv_derived_from_sv(sv, klass, flags) (sv_derived_from((sv), SvPV_nolen(klass)))
#endif

#ifndef ptr_table_new
#include "ptr_table.h"
#define PTR_TABLE_DESTRUCTOR &my_ptr_table_free
#else
#define PTR_TABLE_DESTRUCTOR &Perl_ptr_table_free
#endif

typedef struct st_store_cxt store_cxt_t;
struct st_store_cxt {
	int cloning;		/* type of traversal operation */

	PTR_TBL_t *pseen;	/* We have to store tag+1, because tag
                                   numbers start at 0, and we can't
                                   store (SV *) 0 in a ptr_table
                                   without it being confused for a
                                   fetch lookup failure.  */

	HV *hseen;		/* Still need hseen for the 0.6 file format code. */
	AV *hook_seen;		/* which SVs were returned by STORABLE_freeze() */
	IV where_is_undef;	/* index in aseen of PL_sv_undef */
	PTR_TBL_t *pclass;	/* which classnames have been seen, store time */
	HV *hook;		/* cache for hook methods per class name */
	IV tagnum;		/* incremented at store time for each seen object */
	IV classnum;		/* incremented at store time for each seen classname */
	int netorder;		/* true if network order used */
	int deparse;		/* whether to deparse code refs */
	int canonical;		/* whether to store hashes sorted by key */
        SV *output_sv;
	PerlIO *output_fh;	/* where I/O are performed, NULL for memory */
};

typedef struct st_retrieve_cxt retrieve_cxt_t;
typedef SV* (*sv_retrieve_t)(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *name);

struct st_retrieve_cxt {
	int cloning;		/* type of traversal operation */
	HV *hseen;			
	AV *aseen;		/* which objects have been seen, retrieve time */
	IV where_is_undef;	/* index in aseen of PL_sv_undef */
	AV *aclass;		/* which classnames have been seen, retrieve time */
	HV *hook;		/* cache for hook methods per class name */
	IV tagnum;		/* incremented at store time for each seen object */
	IV classnum;		/* incremented at store time for each seen classname */
        SV *rv;                 /* used for calling sv_bless */
	int netorder;		/* true if network order used */
	int is_tainted;		/* true if input source is tainted, at retrieve time */
	SV *eval;		/* whether to eval source code */
#ifndef HAS_UTF8_ALL
        int use_bytes;		/* whether to bytes-ify utf8 */
#endif
        int accept_future_minor;/* croak immediately on future minor versions?  */
	SV *keybuf;	        /* for hash key retrieval */
        const unsigned char *input;
        const unsigned char *input_end;
	PerlIO *input_fh;	/* where I/O are performed, NULL for memory */
	int ver_major;		/* major of version for retrieved object */
	int ver_minor;		/* minor of version for retrieved object */
	sv_retrieve_t *retrieve_vtbl;	/* retrieve dispatch table */
        int on_magic_check;	/* forces a particular error while we read the magic header, for backward comp. */
};

#define CROAK(x)	STMT_START { croak x; } STMT_END

/*
 * LOW_32BITS
 *
 * Keep only the low 32 bits of a pointer (used for tags, which are not
 * really pointers).
 */

#if PTRSIZE <= 4
#define LOW_32BITS(x)	((I32) (x))
#else
#define LOW_32BITS(x)	((I32) ((unsigned long) (x) & 0xffffffffUL))
#endif

/*
 * oI, oS, oC
 *
 * Hack for Crays, where sizeof(I32) == 8, and which are big-endians.
 * Used in the RLEN macros.
 */

#if INTSIZE > 4
#define oI(x)	((char *) (x) + 4))
#define oS(x)	((x) - 4)
#define oC(x)	(x = 0)
#define CRAY_HACK
#else
#define oI(x)	((char *)(x))
#define oS(x)	(x)
#define oC(x)
#endif

static void
croak_io_error(pTHX_ SSize_t rc, retrieve_cxt_t *retrieve_cxt, const char *str) {
        const char *error;
        if (rc < 0) {
                SV *ioe = GvSV(gv_fetchpvs("!", GV_ADDMULTI, SVt_PV));
                error = SvPV_nolen(ioe);
        }
        else
                error = "unexpected EOF reached";
        
        if (retrieve_cxt && retrieve_cxt->on_magic_check)
                Perl_croak(aTHX_
                           "Magic number checking on storable %s failed: %s",
                           (retrieve_cxt->input_fh ? "file" : "string"),
                           error);
        else
                Perl_croak(aTHX_ "%s: %s", (char *)str, (char*)error);
}

#define READ_ERROR(bytes)                                          \
        (croak_io_error(aTHX_ (bytes), retrieve_cxt, "Read error"))

#define WRITE_ERROR(bytes)                                         \
        (croak_io_error(aTHX_ (bytes), NULL, "Write error"))

static void
write_bytes(pTHX_ store_cxt_t *store_cxt, const char *str, STRLEN len) {
        if (len) {
                if (store_cxt->output_fh) {
                        SSize_t bytes = PerlIO_write(store_cxt->output_fh, str, len);
                        if (bytes != len) WRITE_ERROR(bytes);
                }
                else sv_catpvn(store_cxt->output_sv, str, len);
        }
}

#define WRITE_BYTES(x,y)                                \
        (write_bytes(aTHX_ store_cxt, (x), (y)))

#define WRITE_MARK(c)                                          \
        STMT_START {                                           \
                char str = c;                                  \
                write_bytes(aTHX_ store_cxt, &str, 1);         \
        } STMT_END

static void
write_i32n(pTHX_ store_cxt_t *store_cxt, I32 i32) {
#ifdef HAS_HTONL
        i32 = htonl(i32);
#endif
        write_bytes(aTHX_ store_cxt, oI(&i32), 4);
}

#define WRITE_I32N(x)                           \
        (write_i32n(aTHX_ store_cxt, (x)))

static void
write_i32(pTHX_ store_cxt_t *store_cxt, I32 i32) {
#ifdef HAS_HTONL
        if (store_cxt->netorder)
                i32 = htonl(i32);
#endif
        write_bytes(aTHX_ store_cxt, oI(&i32), 4);
}

#define WRITE_I32(x)                                                    \
        STMT_START {                                                    \
                ASSERT(sizeof(x) == sizeof(I32), ("writing an I32"));   \
                write_i32(aTHX_ store_cxt, (x));                        \
        } STMT_END

#define WRITE_LEN(len)                                                  \
        STMT_START {                                                    \
                if (len > I32_MAX)                                      \
                        Perl_croak(aTHX_ "data length too big: %"UVuf , \
                                   (UV)len);                            \
                write_i32(aTHX_ store_cxt, len);                        \
        } STMT_END

static void
write_pv_with_len(pTHX_ store_cxt_t *store_cxt, const char *pv, STRLEN len) {
        WRITE_LEN(len);
        WRITE_BYTES(pv, len);
}

#define WRITE_PV_WITH_LEN(pv, len)              \
	(write_pv_with_len(aTHX_ store_cxt, pv, len))             

static void
write_pv_with_len_and_type(pTHX_ store_cxt_t *store_cxt, const char *pv, STRLEN len, char type) {
        if (len < LG_SCALAR) {
                WRITE_MARK(type);
                WRITE_MARK(len);
                WRITE_BYTES(pv, len);
        }
        else {
                switch (type) {
                case SX_SCALAR:
                        type = SX_LSCALAR;
                        break;
                case SX_UTF8STR:
                        type = SX_LUTF8STR;
                        break;
                case SX_VSTRING:
                        type = SX_LVSTRING;
                        break;
                default:
                        Perl_croak(aTHX_ "unexpected type %i passed to write_pv_with_len_and_type", (int)type);
                }
                WRITE_MARK(type);
                WRITE_PV_WITH_LEN(pv, len);
        }
}

#define WRITE_PV_WITH_LEN_AND_TYPE(pv, len, type)                       \
	(write_pv_with_len_and_type(aTHX_ store_cxt, (pv), (len), (type)))


/*
 * Possible return values for sv_type().
 */

#define svis_REF		0
#define svis_SCALAR		1
#define svis_ARRAY		2
#define svis_HASH		3
#define svis_TIED		4
#define svis_TIED_ITEM	5
#define svis_CODE		6
#define svis_OTHER		7

/*
 * Flags for SX_HOOK.
 */

#define SHF_TYPE_MASK		0x03
#define SHF_LARGE_CLASSLEN	0x04
#define SHF_LARGE_STRLEN	0x08
#define SHF_LARGE_LISTLEN	0x10
#define SHF_IDX_CLASSNAME	0x20
#define SHF_NEED_RECURSE	0x40
#define SHF_HAS_LIST		0x80

/*
 * Types for SX_HOOK (last 2 bits in flags).
 */

#define SHT_SCALAR			0
#define SHT_ARRAY			1
#define SHT_HASH			2
#define SHT_EXTRA			3		/* Read extra byte for type */

/*
 * The following are held in the "extra byte"...
 */

#define SHT_TSCALAR			4		/* 4 + 0 -- tied scalar */
#define SHT_TARRAY			5		/* 4 + 1 -- tied array */
#define SHT_THASH			6		/* 4 + 2 -- tied hash */

/*
 * per hash flags for flagged hashes
 */

#define SHV_RESTRICTED		0x01

/*
 * per key flags for flagged hashes
 */

#define SHV_K_UTF8		0x01
#define SHV_K_WASUTF8		0x02
#define SHV_K_LOCKED		0x04
#define SHV_K_ISSV		0x08
#define SHV_K_PLACEHOLDER	0x10

/*
 * Before 0.6, the magic string was "perl-store" (binary version number 0).
 *
 * Since 0.6 introduced many binary incompatibilities, the magic string has
 * been changed to "pst0" to allow an old image to be properly retrieved by
 * a newer Storable, but ensure a newer image cannot be retrieved with an
 * older version.
 *
 * At 0.7, objects are given the ability to serialize themselves, and the
 * set of markers is extended, backward compatibility is not jeopardized,
 * so the binary version number could have remained unchanged.  To correctly
 * spot errors if a file making use of 0.7-specific extensions is given to
 * 0.6 for retrieval, the binary version was moved to "2".  And I'm introducing
 * a "minor" version, to better track this kind of evolution from now on.
 * 
 */
static const char old_magicstr[] = "perl-store"; /* Magic number before 0.6 */
static const char magicstr[] = "pst0";		 /* Used as a magic number */

#define MAGICSTR_BYTES  'p','s','t','0'
#define OLDMAGICSTR_BYTES  'p','e','r','l','-','s','t','o','r','e'

/* 5.6.x introduced the ability to have IVs as long long.
   However, Configure still defined BYTEORDER based on the size of a long.
   Storable uses the BYTEORDER value as part of the header, but doesn't
   explicitly store sizeof(IV) anywhere in the header.  Hence on 5.6.x built
   with IV as long long on a platform that uses Configure (ie most things
   except VMS and Windows) headers are identical for the different IV sizes,
   despite the files containing some fields based on sizeof(IV)
   Erk. Broken-ness.
   5.8 is consistent - the following redefinition kludge is only needed on
   5.6.x, but the interwork is needed on 5.8 while data survives in files
   with the 5.6 header.

*/

#if defined (IVSIZE) && (IVSIZE == 8) && (LONGSIZE == 4)
#ifndef NO_56_INTERWORK_KLUDGE
#define USE_56_INTERWORK_KLUDGE
#endif
#if BYTEORDER == 0x1234
#undef BYTEORDER
#define BYTEORDER 0x12345678
#else
#if BYTEORDER == 0x4321
#undef BYTEORDER
#define BYTEORDER 0x87654321
#endif
#endif
#endif

#if BYTEORDER == 0x1234
#define BYTEORDER_BYTES  '1','2','3','4'
#else
#if BYTEORDER == 0x12345678
#define BYTEORDER_BYTES  '1','2','3','4','5','6','7','8'
#ifdef USE_56_INTERWORK_KLUDGE
#define BYTEORDER_BYTES_56  '1','2','3','4'
#endif
#else
#if BYTEORDER == 0x87654321
#define BYTEORDER_BYTES  '8','7','6','5','4','3','2','1'
#ifdef USE_56_INTERWORK_KLUDGE
#define BYTEORDER_BYTES_56  '4','3','2','1'
#endif
#else
#if BYTEORDER == 0x4321
#define BYTEORDER_BYTES  '4','3','2','1'
#else
#error Unknown byteorder. Please append your byteorder to Storable.xs
#endif
#endif
#endif
#endif

static const char byteorderstr[] = {BYTEORDER_BYTES, 0};
#ifdef USE_56_INTERWORK_KLUDGE
static const char byteorderstr_56[] = {BYTEORDER_BYTES_56, 0};
#endif

#define STORABLE_BIN_MAJOR	2		/* Binary major "version" */
#define STORABLE_BIN_MINOR	9		/* Binary minor "version" */

#if (PATCHLEVEL <= 5)
#define STORABLE_BIN_WRITE_MINOR	4
#elif !defined (SvVOK)
/*
 * Perl 5.6.0-5.8.0 can do weak references, but not vstring magic.
*/
#define STORABLE_BIN_WRITE_MINOR	8
#else
#define STORABLE_BIN_WRITE_MINOR	9
#endif /* (PATCHLEVEL <= 5) */

#if (PATCHLEVEL < 8 || (PATCHLEVEL == 8 && SUBVERSION < 1))
#define PL_sv_placeholder PL_sv_undef
#endif

/*
 * Useful store shortcuts...
 */

#define WRITE_SCALAR(pv, len)	WRITE_PV_WITH_LEN_AND_TYPE(pv, len, SX_SCALAR)

/*
 * Store &PL_sv_undef in arrays without recursing through store().
 */
#define WRITE_SV_UNDEF()                        \
        STMT_START {                            \
                store_cxt->tagnum++;            \
                WRITE_MARK(SX_SV_UNDEF);        \
        } STMT_END

/*
 * Useful retrieve shortcuts...
 */

static void
read_bytes(pTHX_ retrieve_cxt_t *retrieve_cxt, char *buf, STRLEN size) {
        if (retrieve_cxt->input_fh) {
                if (size) {
                        SSize_t bytes = PerlIO_read(retrieve_cxt->input_fh, buf, size);
                        if (bytes != size) READ_ERROR(bytes);
                }
        }
        else {
                if ((retrieve_cxt->input + size) <= retrieve_cxt->input_end) {
                        Move(retrieve_cxt->input, buf, size, char);
                        retrieve_cxt->input += size;
                }
                else
                        READ_ERROR(0);
        }
}

#define READ_BYTES(x,y)                                         \
        (read_bytes(aTHX_ retrieve_cxt, (char *)(x), y))

static unsigned char
read_uchar(pTHX_ retrieve_cxt_t *retrieve_cxt) {
        unsigned char b;
        READ_BYTES(&b, 1);
        return b;
}

#define READ_UCHAR(x)                                    \
        STMT_START {                                     \
                x = read_uchar(aTHX_ retrieve_cxt);      \
        } STMT_END

static I32
read_i32n(pTHX_ retrieve_cxt_t *retrieve_cxt) {
        I32 x;
        oC(x);
        READ_BYTES(oI(&x), 4);
#ifdef HAS_NTOHL
        x = ntohl(x);
#endif
        return x;
}

static I32
read_i32(pTHX_ retrieve_cxt_t *retrieve_cxt) {
        I32 x;
        oC(x);
        READ_BYTES(oI(&x), 4);
#ifdef HAS_NTOHL
        if (retrieve_cxt->netorder)
                x = ntohl(x);
#endif
        return x;
}

#define READ_I32(x)                                                     \
        STMT_START {							\
                ASSERT(sizeof(x) == sizeof(I32), ("reading an I32"));   \
                x = read_i32(aTHX_ retrieve_cxt);                       \
        } STMT_END

#define READ_I32N(x)                                                    \
        STMT_START {							\
                ASSERT(sizeof(x) == sizeof(I32), ("reading an I32"));   \
                x = read_i32n(aTHX_ retrieve_cxt);                      \
        } STMT_END


#define READ_VARINT(l, x)                          \
        STMT_START {                            \
                if (l)                          \
                        READ_I32(x);            \
                else                            \
                        READ_UCHAR(x);          \
        } STMT_END

static const char *
read_into_sv(pTHX_ retrieve_cxt_t *retrieve_cxt, STRLEN size, SV *out) {
	char *pv;
	SvUPGRADE(out, SVt_PV);
	pv = SvGROW(out, size + 1);
        READ_BYTES(pv, size);
	pv[size] = '\0';
	SvPOK_only(out);
	SvCUR_set(out, size);
	return pv;
}

static SV *
read_svpv(pTHX_ retrieve_cxt_t *retrieve_cxt, STRLEN size) {
	SV *sv = sv_newmortal();
	read_into_sv(aTHX_ retrieve_cxt, size, sv);
        if (retrieve_cxt->is_tainted)
                SvTAINT(sv);
        SvREFCNT_inc_NN(sv);
        return sv;
}

#define READ_SVPV(sv, size)                                     \
	STMT_START {                                            \
		sv = read_svpv(aTHX_ retrieve_cxt, size);	\
	} STMT_END

/*
 * key buffer handling
 */

#define READ_KEY(kbuf, size)						\
	STMT_START {							\
		kbuf = read_into_sv(aTHX_ retrieve_cxt,                 \
                                    (size), retrieve_cxt->keybuf);      \
	} STMT_END


static void
av_store_safe(pTHX_ AV *av, I32 key, SV *val) {
        if (!av_store(av, key, val)) {
                SvREFCNT_dec(val);
                Perl_croak(aTHX_ "Internal error: av_store failed");
        }
}

static void
hv_store_safe(pTHX_ HV *hv, const char *key, I32 klen, SV *val) {
    if (!hv_store(hv, key, klen, val, 0)) {
        SvREFCNT_dec(val);
        Perl_croak(aTHX_ "Internal error: hv_store failed");
    }
}

/*
 * This macro is used at retrieve time, to remember where object 'y', bearing a
 * given tag 'tagnum', has been retrieved. Next time we see an SX_OBJECT marker,
 * we'll therefore know where it has been retrieved and will be able to
 * share the same reference, as in the original stored memory image.
 *
 * We also need to bless objects ASAP for hooks (which may compute "ref $x"
 * on the objects given to STORABLE_thaw and expect that to be defined), and
 * also for overloaded objects (for which we might not find the stash if the
 * object is not blessed yet--this might occur for overloaded objects that
 * refer to themselves indirectly: if we blessed upon return from a sub
 * retrieve(), the SX_OBJECT marker we'd found could not have overloading
 * restored on it because the underlying object would not be blessed yet!).
 *
 * To achieve that, the class name of the last retrieved object is passed down
 * recursively, and the first SEEN() call for which the class name is not NULL
 * will bless the object.
 */
#define SEEN_no_inc(y, c)                                               \
    STMT_START {                                                        \
        ASSERT(y, ("SEEN argument is not NULL"));                       \
        av_store_safe(aTHX_                                             \
                      retrieve_cxt->aseen,                              \
                      retrieve_cxt->tagnum++,                           \
                      (SV*)(y));                                        \
        TRACEME(("aseen(#%d) = 0x%"UVxf" (refcnt=%d)",                  \
                 retrieve_cxt->tagnum-1, PTR2UV(y), SvREFCNT(y)-1));    \
        if (c)                                                          \
            BLESS((SV *) (y), c);                                       \
    } STMT_END

#define SEEN(y,c) 							\
    STMT_START {                                                        \
        ASSERT(y, ("SEEN argument is not NULL"));                       \
        SvREFCNT_inc_NN((SV*)(y));                                      \
        SEEN_no_inc(y, c);                                              \
    } STMT_END


static void bless_retrieved(pTHX_ retrieve_cxt_t *retrieve_cxt, SV *sv, const char *class_pv) {
        HV *stash = gv_stashpv(class_pv, GV_ADD);
        SV *rv = retrieve_cxt->rv;
        SvRV_set(rv, sv);
        sv_bless(rv, stash);
        SvRV_set(rv, &PL_sv_undef);
}

/*
 * Bless 's' in 'p', via a temporary reference (cached on the
 * context), required by sv_bless().
 */
#define BLESS(s,p)                                      \
        (bless_retrieved(aTHX_ retrieve_cxt, s, p))

static void store(pTHX_ store_cxt_t *store_cxt, SV *sv);
static SV *retrieve(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname);

/*
 * Dynamic dispatching table for SV store.
 */

static void store_ref(pTHX_ store_cxt_t *store_cxt, SV *sv);
static void store_scalar(pTHX_ store_cxt_t *store_cxt, SV *sv);
static void store_array(pTHX_ store_cxt_t *store_cxt, AV *av);
static void store_hash(pTHX_ store_cxt_t *store_cxt, HV *hv);
static void store_tied(pTHX_ store_cxt_t *store_cxt, SV *sv);
static void store_tied_item(pTHX_ store_cxt_t *store_cxt, SV *sv);
static void store_code(pTHX_ store_cxt_t *store_cxt, CV *cv);
static void store_other(pTHX_ store_cxt_t *store_cxt, SV *sv);
static void store_blessed(pTHX_ store_cxt_t *store_cxt, SV *sv, int type, HV *pkg);

typedef void (*sv_store_t)(pTHX_ store_cxt_t *store_cxt, SV *sv);

static const sv_store_t sv_store[] = {
	(sv_store_t)store_ref,		/* svis_REF */
	(sv_store_t)store_scalar,	/* svis_SCALAR */
	(sv_store_t)store_array,	/* svis_ARRAY */
	(sv_store_t)store_hash,		/* svis_HASH */
	(sv_store_t)store_tied,		/* svis_TIED */
	(sv_store_t)store_tied_item,	/* svis_TIED_ITEM */
	(sv_store_t)store_code,		/* svis_CODE */
	(sv_store_t)store_other,	/* svis_OTHER */
};

#define SV_STORE(x)	(*sv_store[x])

/*
 * Dynamic dispatching tables for SV retrieval.
 */

static SV *retrieve_lscalar(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname);
static SV *retrieve_lutf8str(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname);
static SV *old_retrieve_array(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname);
static SV *old_retrieve_hash(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname);
static SV *retrieve_ref(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname);
static SV *retrieve_undef(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname);
static SV *retrieve_integer(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname);
static SV *retrieve_double(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname);
static SV *retrieve_byte(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname);
static SV *retrieve_netint(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname);
static SV *retrieve_scalar(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname);
static SV *retrieve_utf8str(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname);
static SV *retrieve_tied_array(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname);
static SV *retrieve_tied_hash(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname);
static SV *retrieve_tied_scalar(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname);
static SV *retrieve_other(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname);

static sv_retrieve_t sv_old_retrieve[] = {
	0,			/* SX_OBJECT -- entry unused dynamically */
	retrieve_lscalar,	/* SX_LSCALAR */
	(sv_retrieve_t)old_retrieve_array,	/* SX_ARRAY -- for pre-0.6 binaries */
	(sv_retrieve_t)old_retrieve_hash,	/* SX_HASH -- for pre-0.6 binaries */
	(sv_retrieve_t)retrieve_ref,		/* SX_REF */
	(sv_retrieve_t)retrieve_undef,		/* SX_UNDEF */
	(sv_retrieve_t)retrieve_integer,	/* SX_INTEGER */
	(sv_retrieve_t)retrieve_double,		/* SX_DOUBLE */
	(sv_retrieve_t)retrieve_byte,		/* SX_BYTE */
	(sv_retrieve_t)retrieve_netint,		/* SX_NETINT */
	(sv_retrieve_t)retrieve_scalar,		/* SX_SCALAR */
	(sv_retrieve_t)retrieve_tied_array,	/* SX_ARRAY */
	(sv_retrieve_t)retrieve_tied_hash,	/* SX_HASH */
	(sv_retrieve_t)retrieve_tied_scalar,	/* SX_SCALAR */
	(sv_retrieve_t)retrieve_other,	/* SX_SV_UNDEF not supported */
	(sv_retrieve_t)retrieve_other,	/* SX_SV_YES not supported */
	(sv_retrieve_t)retrieve_other,	/* SX_SV_NO not supported */
	(sv_retrieve_t)retrieve_other,	/* SX_BLESS not supported */
	(sv_retrieve_t)retrieve_other,	/* SX_IX_BLESS not supported */
	(sv_retrieve_t)retrieve_other,	/* SX_HOOK not supported */
	(sv_retrieve_t)retrieve_other,	/* SX_OVERLOADED not supported */
	(sv_retrieve_t)retrieve_other,	/* SX_TIED_KEY not supported */
	(sv_retrieve_t)retrieve_other,	/* SX_TIED_IDX not supported */
	(sv_retrieve_t)retrieve_other,	/* SX_UTF8STR not supported */
	(sv_retrieve_t)retrieve_other,	/* SX_LUTF8STR not supported */
	(sv_retrieve_t)retrieve_other,	/* SX_FLAG_HASH not supported */
	(sv_retrieve_t)retrieve_other,	/* SX_CODE not supported */
	(sv_retrieve_t)retrieve_other,	/* SX_WEAKREF not supported */
	(sv_retrieve_t)retrieve_other,	/* SX_WEAKOVERLOAD not supported */
	(sv_retrieve_t)retrieve_other,	/* SX_VSTRING not supported */
	(sv_retrieve_t)retrieve_other,	/* SX_LVSTRING not supported */
	(sv_retrieve_t)retrieve_other,	/* SX_ERROR */
};

static SV *retrieve_array(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname);
static SV *retrieve_hash(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname);
static SV *retrieve_sv_undef(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname);
static SV *retrieve_sv_yes(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname);
static SV *retrieve_sv_no(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname);
static SV *retrieve_blessed(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname);
static SV *retrieve_idx_blessed(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname);
static SV *retrieve_hook(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname);
static SV *retrieve_overloaded(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname);
static SV *retrieve_tied_key(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname);
static SV *retrieve_tied_idx(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname);
static SV *retrieve_flag_hash(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname);
static SV *retrieve_code(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname);
static SV *retrieve_weakref(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname);
static SV *retrieve_weakoverloaded(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname);
static SV *retrieve_vstring(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname);
static SV *retrieve_lvstring(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname);

static sv_retrieve_t sv_retrieve[] = {
	0,			/* SX_OBJECT -- entry unused dynamically */
	(sv_retrieve_t)retrieve_lscalar,	/* SX_LSCALAR */
	(sv_retrieve_t)retrieve_array,		/* SX_ARRAY */
	(sv_retrieve_t)retrieve_hash,		/* SX_HASH */
	(sv_retrieve_t)retrieve_ref,		/* SX_REF */
	(sv_retrieve_t)retrieve_undef,		/* SX_UNDEF */
	(sv_retrieve_t)retrieve_integer,	/* SX_INTEGER */
	(sv_retrieve_t)retrieve_double,		/* SX_DOUBLE */
	(sv_retrieve_t)retrieve_byte,		/* SX_BYTE */
	(sv_retrieve_t)retrieve_netint,		/* SX_NETINT */
	(sv_retrieve_t)retrieve_scalar,		/* SX_SCALAR */
	(sv_retrieve_t)retrieve_tied_array,	/* SX_ARRAY */
	(sv_retrieve_t)retrieve_tied_hash,	/* SX_HASH */
	(sv_retrieve_t)retrieve_tied_scalar,	/* SX_SCALAR */
	(sv_retrieve_t)retrieve_sv_undef,	/* SX_SV_UNDEF */
	(sv_retrieve_t)retrieve_sv_yes,		/* SX_SV_YES */
	(sv_retrieve_t)retrieve_sv_no,		/* SX_SV_NO */
	(sv_retrieve_t)retrieve_blessed,	/* SX_BLESS */
	(sv_retrieve_t)retrieve_idx_blessed,	/* SX_IX_BLESS */
	(sv_retrieve_t)retrieve_hook,		/* SX_HOOK */
	(sv_retrieve_t)retrieve_overloaded,	/* SX_OVERLOAD */
	(sv_retrieve_t)retrieve_tied_key,	/* SX_TIED_KEY */
	(sv_retrieve_t)retrieve_tied_idx,	/* SX_TIED_IDX */
	(sv_retrieve_t)retrieve_utf8str,	/* SX_UTF8STR  */
	(sv_retrieve_t)retrieve_lutf8str,	/* SX_LUTF8STR */
	(sv_retrieve_t)retrieve_flag_hash,	/* SX_HASH */
	(sv_retrieve_t)retrieve_code,		/* SX_CODE */
	(sv_retrieve_t)retrieve_weakref,	/* SX_WEAKREF */
	(sv_retrieve_t)retrieve_weakoverloaded,	/* SX_WEAKOVERLOAD */
	(sv_retrieve_t)retrieve_vstring,	/* SX_VSTRING */
	(sv_retrieve_t)retrieve_lvstring,	/* SX_LVSTRING */
	(sv_retrieve_t)retrieve_other,		/* SX_ERROR */
};

#define RETRIEVE(c,x) (*(c)->retrieve_vtbl[(x) >= SX_ERROR ? SX_ERROR : (x)])

/***
 *** Context management.
 ***/

/*
 * init_store_cxt
 *
 * Initialize a new store context.
 */
static void init_store_cxt(
        pTHX_
	store_cxt_t *store_cxt,
	PerlIO *f,
	int network_order)
{
	TRACEME(("init_store_cxt"));

        Zero(store_cxt, 1, store_cxt_t);

	store_cxt->netorder = network_order;
	store_cxt->deparse = -1;				/* Idem */
	store_cxt->canonical = -1;			/* Idem */
	store_cxt->tagnum = -1;				/* Reset tag numbers */
	store_cxt->output_fh = f;					/* Where I/O are performed */

	if (!f) {
                store_cxt->output_sv = sv_2mortal(newSV(512));
                SvPOK_only(store_cxt->output_sv);
        }

	/*
	 * The 'pseen' table is used to keep track of each SV stored and their
	 * associated tag numbers is special.
         */
	store_cxt->pseen = ptr_table_new();
        SAVEDESTRUCTOR_X(PTR_TABLE_DESTRUCTOR, store_cxt->pseen);
	/*
	 * The following does not work well with perl5.004_04, and causes
	 * a core dump later on, in a completely unrelated spot, which
	 * makes me think there is a memory corruption going on.
         */

	/*
	 * The 'pclass' table uses the same settings as 'pseen' above, but it is
	 * used to assign sequential tags (numbers) to class stashes.
	 */
        store_cxt->pclass = ptr_table_new();
        SAVEDESTRUCTOR_X(PTR_TABLE_DESTRUCTOR, store_cxt->pclass);

	/*
	 * The 'hook' hash table is used to keep track of the references on
	 * the STORABLE_freeze hook routines, when found in some class name.
	 *
	 * It is assumed that the inheritance tree will not be changed during
	 * storing, and that no new method will be dynamically created by the
	 * hooks.
	 */
	store_cxt->hook = (HV*)sv_2mortal((SV*)newHV()); /* Table where hooks are cached */

	/*
	 * The 'hook_seen' array keeps track of all the SVs returned by
	 * STORABLE_freeze hooks for us to serialize, so that they are not
	 * reclaimed until the end of the serialization process.  Each SV is
	 * only stored once, the first time it is seen.
	 */
	store_cxt->hook_seen = (AV*)sv_2mortal((SV*)newAV()); /* Lists SVs returned by STORABLE_freeze */
}

/*
 * init_retrieve_cxt
 *
 * Initialize a new retrieve context.
 */
static void init_retrieve_cxt(pTHX_ retrieve_cxt_t *retrieve_cxt)
{
	TRACEME(("init_retrieve_cxt"));
	Zero(retrieve_cxt, 1, retrieve_cxt_t);

	/*
	 * The hook hash table is used to keep track of the references on
	 * the STORABLE_thaw hook routines, when found in some class name.
	 *
	 * It is assumed that the inheritance tree will not be changed during
	 * storing, and that no new method will be dynamically created by the
	 * hooks.
	 */

	retrieve_cxt->hook  = (HV*)sv_2mortal((SV*)newHV()); /* Caches STORABLE_thaw */

	/*
	 * If retrieving an old binary version, the retrieve_cxt->retrieve_vtbl variable
	 * was set to sv_old_retrieve. We'll need a hash table to keep track of
	 * the correspondence between the tags and the tag number used by the
	 * new retrieve routines.
	 */

	retrieve_cxt->aseen = (AV*)sv_2mortal((SV*)newAV()); /* Where retrieved objects are kept */
	retrieve_cxt->where_is_undef = -1;		/* Special case for PL_sv_undef */
	retrieve_cxt->aclass = (AV*)sv_2mortal((SV*)newAV()); /* Where seen classnames are kept */

#ifndef HAS_UTF8_ALL
        retrieve_cxt->use_bytes = -1;		/* Fetched from perl if needed */
#endif

        retrieve_cxt->accept_future_minor = -1;	/* Fetched from perl if needed */

	retrieve_cxt->keybuf = sv_2mortal(newSV(0));

        retrieve_cxt->eval = sv_mortalcopy(perl_get_sv("Storable::Eval", GV_ADD));

        retrieve_cxt->rv = sv_2mortal(newRV(&PL_sv_undef));
}

static int
forgive_me(pTHX) {
        return SvTRUE(perl_get_sv("Storable::forgive_me", GV_ADD));
}

static int
downgrade_restricted(pTHX) {
        return SvTRUE(perl_get_sv("Storable::downgrade_restricted", GV_ADD));
}

/***
 *** Predicates.
 ***/

/*
 * known_class
 *
 * Lookup the class name in the 'hclass' table and either assign it a new ID
 * or return the existing one, by filling in 'classnum'.
 *
 * Return true if the class was known, false if the ID was just generated.
 */
static int known_class(pTHX_ store_cxt_t *store_cxt, HV *pkg, I32 *classnum) {

        void *tag1;

	TRACEME(("known_class (%s)", HvNAME_get(pkg)));

        tag1 = ptr_table_fetch(store_cxt->pclass, pkg);
        if (tag1) {
                /*
                 * Recall that we don't store pointers in this table, but
                 * tags.  Therefore, we need LOW_32BITS() to extract the
                 * relevant parts.
                 */
                *classnum = LOW_32BITS(((char *)tag1) - 1);
                return TRUE;
        }
        else {
                /* Unknown classname, we need to record it. */
                *classnum = store_cxt->classnum++;

                /* We store classnum + 1 because 0 is not a valid value */
                ptr_table_store(store_cxt->pclass, pkg, INT2PTR(SV*, store_cxt->classnum));
                return FALSE;
        }
}

/***
 *** Specific store routines.
 ***/

/*
 * store_ref
 *
 * Store a reference.
 * Layout is SX_REF <object> or SX_OVERLOAD <object>.
 */
static void store_ref(pTHX_ store_cxt_t *store_cxt, SV *sv)
{
	int is_weak = 0;
	TRACEME(("store_ref (0x%"UVxf")", PTR2UV(sv)));

	/*
	 * Follow reference, and check if target is overloaded.
	 */

#ifdef SvWEAKREF
	if (SvWEAKREF(sv))
		is_weak = 1;
	TRACEME(("ref (0x%"UVxf") is%s weak", PTR2UV(sv), is_weak ? "" : "n't"));
#endif
	sv = SvRV(sv);

	if (SvOBJECT(sv)) {
		HV *stash = (HV *) SvSTASH(sv);
		if (stash && Gv_AMG(stash)) {
			TRACEME(("ref (0x%"UVxf") is overloaded", PTR2UV(sv)));
			WRITE_MARK(is_weak ? SX_WEAKOVERLOAD : SX_OVERLOAD);
		} else
			WRITE_MARK(is_weak ? SX_WEAKREF : SX_REF);
	} else
		WRITE_MARK(is_weak ? SX_WEAKREF : SX_REF);

	store(aTHX_ store_cxt, sv);
}

/*
 * store_scalar
 *
 * Store a scalar.
 *
 * Layout is SX_LSCALAR <length> <data>, SX_SCALAR <length> <data> or SX_UNDEF.
 * SX_LUTF8STR and SX_UTF8STR are used for UTF-8 strings.
 * The <data> section is omitted if <length> is 0.
 *
 * For vstrings, the vstring portion is stored first with
 * SX_LVSTRING <length> <data> or SX_VSTRING <length> <data>, followed by
 * SX_(L)SCALAR or SX_(L)UTF8STR with the actual PV.
 *
 * If integer or double, the layout is SX_INTEGER <data> or SX_DOUBLE <data>.
 * Small integers (within [-127, +127]) are stored as SX_BYTE <byte>.
 */
static void store_scalar(pTHX_ store_cxt_t *store_cxt, SV *sv)
{
	IV iv;
	char *pv;
	STRLEN len;
	U32 flags = SvFLAGS(sv);			/* "cc -O" may put it in register */

	TRACEME(("store_scalar (0x%"UVxf")", PTR2UV(sv)));

	/*
	 * For efficiency, break the SV encapsulation by peaking at the flags
	 * directly without using the Perl macros to avoid dereferencing
	 * sv->sv_flags each time we wish to check the flags.
	 */

	if (!(flags & SVf_OK)) {			/* !SvOK(sv) */
		if (sv == &PL_sv_undef) {
			TRACEME(("immortal undef"));
			WRITE_MARK(SX_SV_UNDEF);
		} else {
			TRACEME(("undef at 0x%"UVxf, PTR2UV(sv)));
			WRITE_MARK(SX_UNDEF);
		}
		return;
	}

	/*
	 * Always store the string representation of a scalar if it exists.
	 * Gisle Aas provided me with this test case, better than a long speach:
	 *
	 *  perl -MDevel::Peek -le '$a="abc"; $a+0; Dump($a)'
	 *  SV = PVNV(0x80c8520)
	 *       REFCNT = 1
	 *       FLAGS = (NOK,POK,pNOK,pPOK)
	 *       IV = 0
	 *       NV = 0
	 *       PV = 0x80c83d0 "abc"\0
	 *       CUR = 3
	 *       LEN = 4
	 *
	 * Write SX_SCALAR, length, followed by the actual data.
	 *
	 * Otherwise, write an SX_BYTE, SX_INTEGER or an SX_DOUBLE as
	 * appropriate, followed by the actual (binary) data. A double
	 * is written as a string if network order, for portability.
	 *
	 * NOTE: instead of using SvNOK(sv), we test for SvNOKp(sv).
	 * The reason is that when the scalar value is tainted, the SvNOK(sv)
	 * value is false.
	 *
	 * The test for a read-only scalar with both POK and NOK set is meant
	 * to quickly detect &PL_sv_yes and &PL_sv_no without having to pay the
	 * address comparison for each scalar we store.
	 */

#define SV_MAYBE_IMMORTAL (SVf_READONLY|SVf_POK|SVf_NOK)

	if ((flags & SV_MAYBE_IMMORTAL) == SV_MAYBE_IMMORTAL) {
		if (sv == &PL_sv_yes) {
			TRACEME(("immortal yes"));
			WRITE_MARK(SX_SV_YES);
		} else if (sv == &PL_sv_no) {
			TRACEME(("immortal no"));
			WRITE_MARK(SX_SV_NO);
		} else {
			pv = SvPV(sv, len);			/* We know it's SvPOK */
			goto string;				/* Share code below */
		}
	} else if (flags & SVf_POK) {
            /* public string - go direct to string read.  */
            goto string_readlen;
        } else if (
#if (PATCHLEVEL <= 6)
            /* For 5.6 and earlier NV flag trumps IV flag, so only use integer
               direct if NV flag is off.  */
            (flags & (SVf_NOK | SVf_IOK)) == SVf_IOK
#else
            /* 5.7 rules are that if IV public flag is set, IV value is as
               good, if not better, than NV value.  */
            flags & SVf_IOK
#endif
            ) {
            iv = SvIV(sv);
            /*
             * Will come here from below with iv set if double is an integer.
             */
          integer:

            /* Sorry. This isn't in 5.005_56 (IIRC) or earlier.  */
#ifdef SVf_IVisUV
            /* Need to do this out here, else 0xFFFFFFFF becomes iv of -1
             * (for example) and that ends up in the optimised small integer
             * case. 
             */
            if ((flags & SVf_IVisUV) && SvUV(sv) > IV_MAX) {
                TRACEME(("large unsigned integer as string, value = %"UVuf, SvUV(sv)));
                goto string_readlen;
            }
#endif
            /*
             * Optimize small integers into a single byte, otherwise store as
             * a real integer (converted into network order if they asked).
             */

            if (iv >= -128 && iv <= 127) {
                unsigned char siv = (unsigned char) (iv + 128);	/* [0,255] */
                WRITE_MARK(SX_BYTE);
                WRITE_MARK(siv);
                TRACEME(("small integer stored as %d", siv));
            } else if (store_cxt->netorder) {
#if IVSIZE > 4
                if (
#ifdef SVf_IVisUV
                    /* Sorry. This isn't in 5.005_56 (IIRC) or earlier.  */
                    ((flags & SVf_IVisUV) && SvUV(sv) > (UV)0x7FFFFFFF) ||
#endif
                    (iv > (IV)0x7FFFFFFF) || (iv < -(IV)0x80000000)) {
                    /* Bigger than 32 bits.  */
                    TRACEME(("large network order integer as string, value = %"IVdf, iv));
                    goto string_readlen;
                }
#endif
                TRACEME(("using network order"));
                WRITE_MARK(SX_NETINT);
                WRITE_I32(iv);
            } else {
                WRITE_MARK(SX_INTEGER);
                WRITE_BYTES((char *)&iv, sizeof(iv));
            }
            
            TRACEME(("ok (integer 0x%"UVxf", value = %"IVdf")", PTR2UV(sv), iv));
	} else if (flags & SVf_NOK) {
            NV nv;
#if (PATCHLEVEL <= 6)
            nv = SvNV(sv);
            /*
             * Watch for number being an integer in disguise.
             */
            if (nv == (NV) (iv = I_V(nv))) {
                TRACEME(("double %"NVff" is actually integer %"IVdf, nv, iv));
                goto integer;		/* Share code above */
            }
#else

            SvIV_please(sv);
	    if (SvIOK_notUV(sv)) {
                iv = SvIV(sv);
                goto integer;		/* Share code above */
            }
            nv = SvNV(sv);
#endif

            if (store_cxt->netorder) {
                TRACEME(("double %"NVff" stored as string", nv));
                goto string_readlen;		/* Share code below */
            }

            WRITE_MARK(SX_DOUBLE);
            WRITE_BYTES((char *)&nv, sizeof(nv));

            TRACEME(("ok (double 0x%"UVxf", value = %"NVff")", PTR2UV(sv), nv));

	} else if (flags & (SVp_POK | SVp_NOK | SVp_IOK)) {
#ifdef SvVOK
	    MAGIC *mg;
#endif

          string_readlen:
            pv = SvPV(sv, len);

            /*
             * Will come here from above  if it was readonly, POK and NOK but
             * neither &PL_sv_yes nor &PL_sv_no.
             */
          string:

#ifdef SvVOK
            if (SvMAGICAL(sv) && (mg = mg_find(sv, 'V')))
                WRITE_PV_WITH_LEN_AND_TYPE((const char *)mg->mg_ptr, mg->mg_len, SX_VSTRING);
#endif

            if (SvUTF8 (sv))
                    WRITE_UTF8STR(pv, len);
            else
                    WRITE_SCALAR(pv, len);
            TRACEME(("ok (scalar 0x%"UVxf" '%s', length = %"IVdf")",
                     PTR2UV(sv), SvPVX(sv), (IV)len));
	} else
            CROAK(("Can't determine type of %s(0x%"UVxf")",
                   sv_reftype(sv, FALSE),
                   PTR2UV(sv)));
        return;		/* Ok, no recursion on scalars */
}

/*
 * store_array
 *
 * Store an array.
 *
 * Layout is SX_ARRAY <size> followed by each item, in increasing index order.
 * Each item is stored as <object>.
 */
static void store_array(pTHX_ store_cxt_t *store_cxt, AV *av)
{
	SV **sav;
	I32 len = av_len(av) + 1;
	I32 i;

	TRACEME(("store_array (0x%"UVxf")", PTR2UV(av)));

	/* 
	 * Signal array by emitting SX_ARRAY, followed by the array length.
	 */

	WRITE_MARK(SX_ARRAY);
        WRITE_LEN(len);
	TRACEME(("size = %d", len));

	/*
	 * Now store each item recursively.
	 */

	for (i = 0; i < len; i++) {
		sav = av_fetch(av, i, 0);
		if (sav) {
                        TRACEME(("(#%d) item", i));
                        store(aTHX_ store_cxt, *sav);
                }
                else {
			TRACEME(("(#%d) undef item", i));
			WRITE_SV_UNDEF();
		}
	}

	TRACEME(("ok (array)"));
}


#if (PATCHLEVEL <= 6)

/*
 * sortcmp
 *
 * Sort two SVs
 * Borrowed from perl source file pp_ctl.c, where it is used by pp_sort.
 */
static int
sortcmp(const void *a, const void *b)
{
        dTHX;
        return sv_cmp(*(SV * const *) a, *(SV * const *) b);
}

#endif /* PATCHLEVEL <= 6 */

/*
 * store_hash
 *
 * Store a hash table.
 *
 * For a "normal" hash (not restricted, no utf8 keys):
 *
 * Layout is SX_HASH <size> followed by each key/value pair, in random order.
 * Values are stored as <object>.
 * Keys are stored as <length> <data>, the <data> section being omitted
 * if length is 0.
 *
 *
 * For a "fancy" hash (restricted or utf8 keys):
 *
 * Layout is SX_FLAG_HASH <size> <hash flags> followed by each key/value pair,
 * in random order.
 * Values are stored as <object>.
 * Keys are stored as <flags> <length> <data>, the <data> section being omitted
 * if length is 0.
 * Currently the only hash flag is "restricted"
 * Key flags are as for hv.h
 */
static void store_hash(pTHX_ store_cxt_t *store_cxt, HV *hv)
{
	dVAR;
	I32 len = HvTOTALKEYS(hv);
	I32 i;
	int ret = 0;
	I32 riter;
	HE *eiter;
        int flagged_hash;
        int restricted;

#ifdef HAS_RESTRICTED_HASHES
        restricted = SvREADONLY(hv);
#else
        restricted = 0;
#endif

#ifdef HAS_HASH_KEY_FLAGS
        flagged_hash = (HvHASKFLAGS(hv) || restricted);
#else
        flagged_hash = restricted;
#endif

#if ((PERL_VERSION == 8) && (PERL_SUBVERSION == 0))
        /* This is a workaround for a bug in 5.8.0 that causes the
           HEK_WASUTF8 flag to be set on an HEK without the hash being
           marked as having key flags. */
        flagged_hash = 1;
#endif

	/* 
	 * Signal hash by emitting SX_HASH or SX_FLAG_HASH, the flags
	 * (when required) and the number of entries.
	 */
        if (flagged_hash) {
                TRACEME(("store_hash (0x%"UVxf"), restricted = %d, size = %d", PTR2UV(hv),
                         restricted, len));
                WRITE_MARK(SX_FLAG_HASH);
                WRITE_MARK(restricted ? SHV_RESTRICTED : 0);
        } else {
                TRACEME(("store_hash (0x%"UVxf"), size = %d", PTR2UV(hv), len));
                WRITE_MARK(SX_HASH);
        }

	WRITE_LEN(len);

	/*
	 * Save possible iteration state via each() on that table.
	 */
	riter = HvRITER_get(hv);
	eiter = HvEITER_get(hv);
	hv_iterinit(hv);

	/*
	 * Now store each item recursively.
	 *
         * If canonical is defined to some true value then store each
         * key/value pair in sorted order otherwise the order is random.
	 * Canonical order is irrelevant when a deep clone operation is performed.
	 *
	 * Fetch the value from perl only once per store() operation, and only
	 * when needed.
	 */

	if (
                /* FIXME: simplify this: */
		!(store_cxt->cloning) && (store_cxt->canonical == 1 ||
			(store_cxt->canonical < 0 && (store_cxt->canonical =
				(SvTRUE(perl_get_sv("Storable::canonical", GV_ADD)) ? 1 : 0))))
	) {
		/*
		 * Storing in order, sorted by key.
		 * Run through the hash, building up an array of keys in a
		 * mortal array, sort the array and then run through the
		 * array.  
		 */

                AV *av = (AV*)sv_2mortal((SV*)newAV());

		TRACEME(("using canonical order"));

		for (i = 0; i < len; i++) {
			SV *key;
                        HE *he;
#ifdef HAS_RESTRICTED_HASHES
			he = hv_iternext_flags(hv, restricted ? HV_ITERNEXT_WANTPLACEHOLDERS : 0);
#else
			he = hv_iternext(hv);
#endif

			if (!he)
				CROAK(("Hash %p inconsistent - expected %d keys, %dth is NULL", hv, (int)len, (int)i));
			key = hv_iterkeysv(he);
			av_store(av, AvFILLp(av)+1, key);	/* av_push(), really */
		}
			
#if (PATCHLEVEL <= 6)
		qsort((char *) AvARRAY(av), len, sizeof(SV *), sortcmp);
#else
		sortsv(AvARRAY(av), len, Perl_sv_cmp);  
#endif

		for (i = 0; i < len; i++) {
                        unsigned char flags = 0;
			char *key_pv;
			STRLEN keylen;
			SV *key = av_shift(av);
			SV *val;
			HE *he;

#ifdef HAS_RESTRICTED_HASHES
			int placeholders = (int)HvPLACEHOLDERS_get(hv);
#endif

			/* This will fail if key is a placeholder.
			   Track how many placeholders we have, and error if we
			   "see" too many.  */
                        he  = hv_fetch_ent(hv, key, 0, 0);
			if (he) {
				val =  HeVAL(he);
                                ASSERT(val, ("HeVAL(he) returns non NULL"));
			} else {
#ifdef HAS_RESTRICTED_HASHES
				/* Should be a placeholder.  */
                                if (restricted && (placeholders > 0)) {
                                        placeholders--;
                                        /* Value is never needed, and PL_sv_undef is
                                           more space efficient to store.  */
                                        val = &PL_sv_undef;
                                        flags = SHV_K_PLACEHOLDER;
                                }
                                else
#endif
                                        Perl_croak(aTHX_ "Hash changed while storing");
                        }

			/*
			 * Store value first.
			 */
			
			TRACEME(("(#%d) value 0x%"UVxf, i, PTR2UV(val)));

			store(aTHX_ store_cxt, val);

			/*
			 * Write key string.
			 * Keys are written after values to make sure retrieval
			 * can be optimal in terms of memory usage, where keys are
			 * read into a fixed unique buffer called kbuf.
			 * See retrieve_hash() for details.
			 */
			 

                        if (flagged_hash) {
                                /* Implementation of restricted hashes isn't nicely
                                   abstracted:  */
                                if (restricted && SvREADONLY(val) && !SvIsCOW(val))
                                        flags |= SHV_K_LOCKED;

#ifdef HAS_UTF8_HASHES
                                /* If you build without optimisation on pre 5.6
                                   then nothing spots that SvUTF8(key) is always 0,
                                   so the block isn't optimised away, at which point
                                   the linker dislikes the reference to
                                   bytes_from_utf8.  */
                                if (SvUTF8(key)) {
                                        if (sv_utf8_downgrade(key, 1)) {
                                                /* If we were able to downgrade here, then than
                                                   means that we have  a key which only had chars
                                                   0-255, but was utf8 encoded.  */
                                                
                                                flags |= SHV_K_WASUTF8;
                                                key_pv = SvPVbyte(key, keylen);
                                        }                                        
                                        else {
                                                flags |= SHV_K_UTF8;
                                                key_pv = SvPVutf8(key, keylen);
                                        }
                                }
                                else
#endif
                                        key_pv = SvPV(key, keylen);
                                
                                WRITE_MARK(flags);
                                TRACEME(("(#%d) key '%s' flags %x %u", i, key_pv, flags, *key_pv));
                        } else {
                                key_pv = SvPV(key, keylen);
                                TRACEME(("(#%d) key '%s'", i, key_pv));
                        }

                        WRITE_PV_WITH_LEN(key_pv, keylen);
		}

	} else {

		/*
		 * Storing in "random" order (in the order the keys are stored
		 * within the hash).  This is the default and will be faster!
		 */
  
		for (i = 0; i < len; i++) {
			char *key = 0;
			I32 key_len;
                        unsigned char flags = 0;
                        HE *he;
			SV *val;
                        SV *key_sv = NULL;
                        HEK *hek;

#ifdef HV_ITERNEXT_WANTPLACEHOLDERS
                        he = hv_iternext_flags(hv, restricted ? HV_ITERNEXT_WANTPLACEHOLDERS : 0);
#else
                        he = hv_iternext(hv);
#endif
                        if (!he)
                                Perl_croak(aTHX_ "Number of entries on hash changed while storing it");
                        
                        val = hv_iterval(hv, he);
                        ASSERT(val, ("hv_iterval returns non NULL"));

                        /* Implementation of restricted hashes isn't nicely
                           abstracted:  */

                        if (restricted) {
                                if (val == &PL_sv_placeholder) {
                                        flags = SHV_K_PLACEHOLDER;
                                        val = &PL_sv_undef;
                                }
                                else if (SvREADONLY(val) && !SvIsCOW(val)) {
                                        flags = SHV_K_LOCKED;
                                }
			}

			/*
			 * Store value first.
			 */

			TRACEME(("(#%d) value 0x%"UVxf, i, PTR2UV(val)));
			store(aTHX_ store_cxt, val);

                        hek = HeKEY_hek(he);
                        key_len = HEK_LEN(hek);
                        if (key_len == HEf_SVKEY) {
                                /* This is somewhat sick, but the internal APIs are
                                 * such that XS code could put one of these in in
                                 * a regular hash.
                                 */
                                key_sv = HeKEY_sv(he);
                                flags |= SHV_K_ISSV;
                        } else {
                                /* Regular string key. */
#ifdef HAS_HASH_KEY_FLAGS
                                if (HEK_UTF8(hek))
                                        flags |= SHV_K_UTF8;
                                if (HEK_WASUTF8(hek))
                                        flags |= SHV_K_WASUTF8;
#endif
                                key = HEK_KEY(hek);
                        }
			/*
			 * Write key string.
			 * Keys are written after values to make sure retrieval
			 * can be optimal in terms of memory usage, where keys are
			 * read into a fixed unique buffer called kbuf.
			 * See retrieve_hash() for details.
			 */

                        if (flagged_hash) {
                                WRITE_MARK(flags);
                                TRACEME(("(#%d) key '%s' flags %x", i, key, flags));
                        }
                        else {
                                ASSERT (flags == 0, ("flags are 0 for non flagged hashes"));
                                TRACEME(("(#%d) key '%s'", i, key));
                        }
                        if (flags & SHV_K_ISSV)
                                store(aTHX_ store_cxt, key_sv);
                        else
                                WRITE_PV_WITH_LEN(key, key_len);
		}
        }

	TRACEME(("ok (hash 0x%"UVxf")", PTR2UV(hv)));

        /* FIXME: Is this always safe? the hash may have changed
         * because of some callback. -- Salva */
	HvRITER_set(hv, riter);		/* Restore hash iterator state */
	HvEITER_set(hv, eiter);

}

/*
 * store_code
 *
 * Store a code reference.
 *
 * Layout is SX_CODE <length> followed by a scalar containing the perl
 * source code of the code reference.
 */
static void store_code(pTHX_ store_cxt_t *store_cxt, CV *cv)
{
#if PERL_VERSION < 6
    /*
	 * retrieve_code does not work with perl 5.005 or less
	 */
	store_other(aTHX_ retrieve_cxt, (SV*)cv);
#else
	dSP;
	I32 len;
	int count, reallen;
	SV *text, *bdeparse;

	TRACEME(("store_code (0x%"UVxf")", PTR2UV(cv)));

	if (
		store_cxt->deparse == 0 ||
		(store_cxt->deparse < 0 && !(store_cxt->deparse =
			SvTRUE(perl_get_sv("Storable::Deparse", GV_ADD)) ? 1 : 0))
	) {
		store_other(aTHX_ store_cxt, (SV*)cv);
		return;
	}

	/*
	 * Require B::Deparse. At least B::Deparse 0.61 is needed for
	 * blessed code references.
	 */
	/* Ownership of both SVs is passed to load_module, which frees them. */
	load_module(PERL_LOADMOD_NOIMPORT, newSVpvn("B::Deparse",10), newSVnv(0.61));
        SPAGAIN;

	ENTER;
	SAVETMPS;

	/*
	 * create the B::Deparse object
	 */

	PUSHMARK(sp);
	XPUSHs(newSVpvs_flags("B::Deparse", SVs_TEMP));
	PUTBACK;
	count = call_method("new", G_SCALAR);
	SPAGAIN;
	if (count != 1)
		CROAK(("Unexpected return value from B::Deparse::new\n"));
	bdeparse = POPs;

	/*
	 * call the coderef2text method
	 */

	PUSHMARK(SP);
        EXTEND(SP, 2);
	PUSHs(bdeparse); /* XXX is this already mortal? */
	PUSHs(sv_2mortal(newRV_inc((SV*)cv)));
	PUTBACK;
	count = call_method("coderef2text", G_SCALAR);
	SPAGAIN;
	if (count != 1)
		CROAK(("Unexpected return value from B::Deparse::coderef2text\n"));

	text = POPs;
        PUTBACK;
	len = SvCUR(text);
	reallen = strlen(SvPV_nolen(text));

	/*
	 * Empty code references or XS functions are deparsed as
	 * "(prototype) ;" or ";".
	 */

	if (len == 0 || *(SvPV_nolen(text)+reallen-1) == ';') {
	    CROAK(("The result of B::Deparse::coderef2text was empty - maybe you're trying to serialize an XS function?\n"));
	}

	/* 
	 * Signal code by emitting SX_CODE.
	 */

	WRITE_MARK(SX_CODE);
	store_cxt->tagnum++;   /* necessary, as SX_CODE is a SEEN() candidate */
	TRACEME(("size = %d", len));
	TRACEME(("code = %s", SvPV_nolen(text)));

	/*
	 * Now store the source code.
	 */

	if(SvUTF8 (text))
		WRITE_UTF8STR(SvPV_nolen(text), len);
	else
		WRITE_SCALAR(SvPV_nolen(text), len);

	FREETMPS;
	LEAVE;

	TRACEME(("ok (code)"));

#endif
}

/*
 * store_tied
 *
 * When storing a tied object (be it a tied scalar, array or hash), we lay out
 * a special mark, followed by the underlying tied object. For instance, when
 * dealing with a tied hash, we store SX_TIED_HASH <hash object>, where
 * <hash object> stands for the serialization of the tied hash.
 */
static void store_tied(pTHX_ store_cxt_t *store_cxt, SV *sv)
{
	MAGIC *mg;
	SV *obj = NULL;
	int ret = 0;
	int svt = SvTYPE(sv);
	char mtype = 'P';

	TRACEME(("store_tied (0x%"UVxf")", PTR2UV(sv)));

	/*
	 * We have a small run-time penalty here because we chose to factorise
	 * all tieds objects into the same routine, and not have a store_tied_hash,
	 * a store_tied_array, etc...
	 *
	 * Don't use a switch() statement, as most compilers don't optimize that
	 * well for 2/3 values. An if() else if() cascade is just fine. We put
	 * tied hashes first, as they are the most likely beasts.
	 */

	if (svt == SVt_PVHV) {
		TRACEME(("tied hash"));
		WRITE_MARK(SX_TIED_HASH);			/* Introduces tied hash */
	} else if (svt == SVt_PVAV) {
		TRACEME(("tied array"));
		WRITE_MARK(SX_TIED_ARRAY);			/* Introduces tied array */
	} else {
		TRACEME(("tied scalar"));
		WRITE_MARK(SX_TIED_SCALAR);		/* Introduces tied scalar */
		mtype = 'q';
	}

	if (!(mg = mg_find(sv, mtype)))
		CROAK(("No magic '%c' found while storing tied %s", mtype,
			(svt == SVt_PVHV) ? "hash" :
				(svt == SVt_PVAV) ? "array" : "scalar"));

	/*
	 * The mg->mg_obj found by mg_find() above actually points to the
	 * underlying tied Perl object implementation. For instance, if the
	 * original SV was that of a tied array, then mg->mg_obj is an AV.
	 *
	 * Note that we store the Perl object as-is. We don't call its FETCH
	 * method along the way. At retrieval time, we won't call its STORE
	 * method either, but the tieing magic will be re-installed. In itself,
	 * that ensures that the tieing semantics are preserved since further
	 * accesses on the retrieved object will indeed call the magic methods...
	 */

	/* [#17040] mg_obj is NULL for scalar self-ties. AMS 20030416 */

	store(aTHX_ store_cxt, (mg->mg_obj ? mg->mg_obj : sv_newmortal()));
	TRACEME(("ok (tied)"));
}

/*
 * store_tied_item
 *
 * Stores a reference to an item within a tied structure:
 *
 *  . \$h{key}, stores both the (tied %h) object and 'key'.
 *  . \$a[idx], stores both the (tied @a) object and 'idx'.
 *
 * Layout is therefore either:
 *     SX_TIED_KEY <object> <key>
 *     SX_TIED_IDX <object> <index>
 */
static void store_tied_item(pTHX_ store_cxt_t *store_cxt, SV *sv)
{
	MAGIC *mg;

	TRACEME(("store_tied_item (0x%"UVxf")", PTR2UV(sv)));

        mg = mg_find(sv, 'p');
	if (!mg)
		CROAK(("No magic 'p' found while storing reference to tied item"));

	/*
	 * We discriminate between \$h{key} and \$a[idx] via mg_ptr.
	 */
	if (mg->mg_ptr) {
		TRACEME(("store_tied_item: storing a ref to a tied hash item"));
		WRITE_MARK(SX_TIED_KEY);
		TRACEME(("store_tied_item: storing OBJ 0x%"UVxf, PTR2UV(mg->mg_obj)));

		store(aTHX_ store_cxt, mg->mg_obj);
		TRACEME(("store_tied_item: storing PTR 0x%"UVxf, PTR2UV(mg->mg_ptr)));

		store(aTHX_ store_cxt, (SV *) mg->mg_ptr);
	} else {
		I32 idx = mg->mg_len;

		TRACEME(("store_tied_item: storing a ref to a tied array item "));
		WRITE_MARK(SX_TIED_IDX);
		TRACEME(("store_tied_item: storing OBJ 0x%"UVxf, PTR2UV(mg->mg_obj)));
                
		store(aTHX_ store_cxt, mg->mg_obj);

		TRACEME(("store_tied_item: storing IDX %d", idx));

		WRITE_LEN(idx);
	}

	TRACEME(("ok (tied item)"));
}

/*
 * store_hook		-- dispatched manually, not via sv_store[]
 *
 * The blessed SV is serialized by a hook.
 *
 * Simple Layout is:
 *
 *     SX_HOOK <flags> <len> <classname> <len2> <str> [<len3> <object-IDs>]
 *
 * where <flags> indicates how long <len>, <len2> and <len3> are, whether
 * the trailing part [] is present, the type of object (scalar, array or hash).
 * There is also a bit which says how the classname is stored between:
 *
 *     <len> <classname>
 *     <index>
 *
 * and when the <index> form is used (classname already seen), the "large
 * classname" bit in <flags> indicates how large the <index> is.
 * 
 * The serialized string returned by the hook is of length <len2> and comes
 * next.  It is an opaque string for us.
 *
 * Those <len3> object IDs which are listed last represent the extra references
 * not directly serialized by the hook, but which are linked to the object.
 *
 * When recursion is mandated to resolve object-IDs not yet seen, we have
 * instead, with <header> being flags with bits set to indicate the object type
 * and that recursion was indeed needed:
 *
 *     SX_HOOK <header> <object> <header> <object> <flags>
 *
 * that same header being repeated between serialized objects obtained through
 * recursion, until we reach flags indicating no recursion, at which point
 * we know we've resynchronized with a single layout, after <flags>.
 *
 * When storing a blessed ref to a tied variable, the following format is
 * used:
 *
 *     SX_HOOK <flags> <extra> ... [<len3> <object-IDs>] <magic object>
 *
 * The first <flags> indication carries an object of type SHT_EXTRA, and the
 * real object type is held in the <extra> flag.  At the very end of the
 * serialization stream, the underlying magic object is serialized, just like
 * any other tied variable.
 *
 * A true return value indicates that the hook succeeded and the
 * object has been already saved. False indicates that the default
 * serialization of the blessed object must continue
 */
static int store_hook(pTHX_ store_cxt_t *store_cxt, SV *sv, int type, HV *pkg, SV *hook, int repeating)
{
        dSP;
	I32 classlen;
        I32 ax;
	char *classname;
	STRLEN frozenlen;
	int count, i;
	unsigned char flags;
	char *frozenpv;
	int obj_type;			/* object type, on 2 bits */
	I32 classnum;
	char mtype = '\0';				/* for blessed ref to tied structures */
	unsigned char eflags = '\0';	/* used when object type is SHT_EXTRA */

	TRACEME(("store_hook, classname \"%s\", tagged #%d", HvNAME_get(pkg), store_cxt->tagnum));

	/*
	 * Determine object type on 2 bits.
	 */

	switch (type) {
        case svis_REF:
	case svis_SCALAR:
		obj_type = SHT_SCALAR;
		break;
	case svis_ARRAY:
		obj_type = SHT_ARRAY;
		break;
	case svis_HASH:
		obj_type = SHT_HASH;
		break;
	case svis_TIED:
		/*
		 * Produced by a blessed ref to a tied data structure, $o in the
		 * following Perl code.
		 *
		 * 	my %h;
		 *  tie %h, 'FOO';
		 *	my $o = bless \%h, 'BAR';
		 *
		 * Signal the tie-ing magic by setting the object type as SHT_EXTRA
		 * (since we have only 2 bits in <flags> to store the type), and an
		 * <extra> byte flag will be emitted after the FIRST <flags> in the
		 * stream, carrying what we put in 'eflags'.
		 */
		obj_type = SHT_EXTRA;
		switch (SvTYPE(sv)) {
		case SVt_PVHV:
			eflags = (unsigned char) SHT_THASH;
			mtype = 'P';
			break;
		case SVt_PVAV:
			eflags = (unsigned char) SHT_TARRAY;
			mtype = 'P';
			break;
		default:
			eflags = (unsigned char) SHT_TSCALAR;
			mtype = 'q';
			break;
		}
		break;
	default:
		CROAK(("Unexpected object type (%d) in store_hook()", type));
	}
	flags = obj_type;

	classname = HvNAME_get(pkg);
	classlen = strlen(classname);

	/*
	 * To call the hook, we need to fake a call like:
	 *
	 *    $object->STORABLE_freeze($cloning);
	 *
	 * but we don't have the $object here.  For instance, if $object is
	 * a blessed array, what we have in 'sv' is the array, and we can't
	 * call a method on those.
	 *
	 * Therefore, we need to create a temporary reference to the object and
	 * make the call on that reference.
	 */

	TRACEME(("about to call STORABLE_freeze on class %s", classname));

        ENTER;
        SAVETMPS;

        PUSHMARK(SP);
        EXTEND(SP, 2);
        PUSHs(sv_2mortal(newRV_inc(sv)));
        PUSHs(sv_2mortal(newSViv(store_cxt->cloning)));
        PUTBACK;

        count = perl_call_sv(hook, G_ARRAY);

	TRACEME(("store_hook, array holds %d items", count));

	if (!count) {
                /*
                 * If they return an empty list, it means they wish to ignore the
                 * hook for this class (and not just this instance -- that's for them
                 * to handle if they so wish).
                 *
                 * Simply disable the cached entry for the hook (it won't be recomputed
                 * since it's present in the cache) and recurse to store_blessed().
                 */

                FREETMPS;
                LEAVE;
		
		if (repeating)
                        /* They must not change their mind in the middle of a serialization. */
			CROAK(("Too late to ignore hooks for %s class \"%s\"",
                               (store_cxt->cloning ? "cloning" : "storing"), classname));

                hv_store(store_cxt->hook, classname, classlen, newSV(0), 0);

		TRACEME(("ignoring STORABLE_freeze in class \"%s\"", classname));

                return 0;
	}

        SPAGAIN; /* this trick documented in perlcall */
        SP -= count;
        ax = (SP - PL_stack_base) + 1;

        /* Write header */
        WRITE_MARK(SX_HOOK);

        if (count > 1) {
                /* STORABLE_attach does not support the extra
                 * references. We use magic as a marker on the hook SV
                 * that the class does not use STORABLE_attach at all */

                if (!SvMAGICAL(hook) || !mg_find(hook, PERL_MAGIC_ext)) {
                        GV* gv = gv_fetchmethod_autoload(pkg, "STORABLE_attach", FALSE);
                        if (gv && isGV(gv))
                                CROAK(("Freeze cannot return references if %s class is using STORABLE_attach", classname));
                        else
                                sv_magic(hook, NULL, PERL_MAGIC_ext, "no STORABLE_attach", 0);
                }
                
                /*
                 * If they returned more than one item, we need to
                 * serialize some extra references if not already
                 * done.
                 *
                 * Loop over the result values and, for each item,
                 * ensure it is a reference, serialize it if not
                 * already done.
                 */

                for (i = 1; i < count; i++) {
                        SV *xsv;
                        AV *av_hook = store_cxt->hook_seen;
                        
                        if (!SvROK(ST(i)))
                                CROAK(("Item #%d returned by STORABLE_freeze "
                                       "for %s is not a reference", i, classname));
                        xsv = SvRV(ST(i));		/* Follow ref to know what to look for */
                        
                        /*
                         * Look in pseen and see if we have a tag already.
                         * Serialize entry if not done already, and get its tag.
                         */
                        
                        if (!ptr_table_fetch(store_cxt->pseen, xsv)) {
                                TRACEME(("listed object %d at 0x%"UVxf" is unknown", i-1, PTR2UV(xsv)));

                                /*
                                 * We need to recurse to store that object and get it to be known
                                 * so that we can resolve the list of object-IDs at retrieve time.
                                 *
                                 * The first time we do this, we need to emit the proper header
                                 * indicating that we recursed, and what the type of object is (the
                                 * object we're storing via a user-hook).  Indeed, during retrieval,
                                 * we'll have to create the object before recursing to retrieve the
                                 * others, in case those would point back at that object.
                                 */

                                /* [SX_HOOK] <flags> [<extra>] <object>*/
                                WRITE_MARK(flags | SHF_NEED_RECURSE);
                                if (eflags) {
                                        WRITE_MARK(eflags);
                                        eflags = '\0'; /* write eflags just once */
                                }

                                store(aTHX_ store_cxt, xsv); /* that may invalidate SP */
                        
                                /*
                                 * It was the first time we serialized 'xsv'.
                                 *
                                 * Keep this SV alive until the end of the serialization: if it gets
                                 * disposed on the FREETMPS, some next temporary value allocated during
                                 * another STORABLE_freeze might take its place, and we'd wrongly assume
                                 * that new SV was already serialized, based on its presence in
                                 * retrieve_cxt->pseen.
                                 *
                                 * Therefore, push it away in retrieve_cxt->hook_seen.
                                 */                        
                                av_store(av_hook, AvFILLp(av_hook) + 1, SvREFCNT_inc_NN(xsv));
                        }                       
                }

                /* SP may have been invalidated by a stack change when recursing */
                SPAGAIN;
                SP -= count;

		flags |= SHF_HAS_LIST;
                if (count - 1 > LG_SCALAR)
                        flags |= SHF_LARGE_LISTLEN;
        }

	/*
	 * Get frozen string.
	 */
	frozenpv = SvPV(ST(0), frozenlen);
	if (frozenlen > LG_SCALAR)
		flags |= SHF_LARGE_STRLEN;

        /*
         * Allocate a class ID if not already done.
         *
         * This needs to be done after the recursion above, since at retrieval
	 * time, we'll see the inner objects first.  Many thanks to
	 * Salvador Ortiz Garcia <sog@msg.com.mx> who spot that bug and
	 * proposed the right fix.  -- RAM, 15/09/2000
	 */
	if (known_class(aTHX_ store_cxt, pkg, &classnum)) {
		TRACEME(("already seen class %s, ID = %d", classname, classnum));
                flags |= SHF_IDX_CLASSNAME;
                if (classnum > LG_SCALAR)
                        flags |= SHF_LARGE_CLASSLEN;
        }
        else {
		TRACEME(("first time we see class %s, ID = %d", classname, classnum));
                if (classlen > LG_SCALAR)
                        flags |= SHF_LARGE_CLASSLEN;
	}

	/* 
	 * We're ready to emit either serialized form:
	 *
	 *   SX_HOOK <flags> [<eflags>] <classlen> <classname> <frozenlen> <str> [<#objects> <object-IDs>]
	 *   SX_HOOK <flags> [<eflags>] <index>           <frozenlen> <str> [<#objects> <object-IDs>]
	 *
	 * If we recursed, the SX_HOOK has already been emitted.
	 */

	TRACEME(("SX_HOOK (recursed=%d) flags=0x%x "
			"class=%"IVdf" classlen=%"IVdf" frozenlen=%"IVdf" #objects=%d",
		 recursed, flags, (IV)classnum, (IV)classlen, (IV)frozenlen, count-1));

	/* SX_HOOK <flags> [<extra>] */
        WRITE_MARK(flags);
        if (eflags)
                WRITE_MARK(eflags);

	/* <classlen> <classname> or <index> */
	if (flags & SHF_IDX_CLASSNAME) {
		if (flags & SHF_LARGE_CLASSLEN)
			WRITE_LEN(classnum);
		else
			WRITE_MARK(classnum);
	}
        else {
		if (flags & SHF_LARGE_CLASSLEN)
			WRITE_LEN(classlen);
		else
			WRITE_MARK(classlen);
		WRITE_BYTES(classname, classlen);		/* Final \0 is omitted */
	}

	/* <frozenlen> <frozen-str> */
	if (flags & SHF_LARGE_STRLEN)
                WRITE_LEN(frozenlen);
	else
		WRITE_MARK(frozenlen);
        WRITE_BYTES(frozenpv, frozenlen);	/* Final \0 is omitted */

	/* [<#objects> <object-IDs>] */
	if (flags & SHF_HAS_LIST) {
		if (flags & SHF_LARGE_LISTLEN)
			WRITE_LEN(count - 1);
		else
			WRITE_MARK(count - 1);

		for (i = 1; i < count; i++) {
                        void *tag1 = ptr_table_fetch(store_cxt->pseen, SvRV(ST(i)));
                        if (tag1) {
                                I32 tag = LOW_32BITS(((char *)tag1) - 1);
                                WRITE_I32N(tag);
                                TRACEME(("object %d, tag #%d", i-1, tag));
                        }
                        else
                                CROAK(("Could not serialize item #%d from hook in %s", i, classname));
		}
	}

        PUTBACK;
        FREETMPS;
	LEAVE;

	/*
	 * If object was tied, need to insert serialization of the magic object.
	 */

	if (obj_type == SHT_EXTRA) {
		MAGIC *mg;

		if (!(mg = mg_find(sv, mtype))) {
			int svt = SvTYPE(sv);
			CROAK(("No magic '%c' found while storing ref to tied %s with hook",
				mtype, (svt == SVt_PVHV) ? "hash" :
					(svt == SVt_PVAV) ? "array" : "scalar"));
		}

		TRACEME(("handling the magic object 0x%"UVxf" part of 0x%"UVxf,
			PTR2UV(mg->mg_obj), PTR2UV(sv)));

		/*
		 * [<magic object>]
		 */

		store(aTHX_ store_cxt, mg->mg_obj);
	}

        return 1;
}

/*
 * store_blessed	-- dispatched manually, not via sv_store[]
 *
 * Check whether there is a STORABLE_xxx hook defined in the class or in one
 * of its ancestors.  If there is, then redispatch to store_hook();
 *
 * Otherwise, the blessed SV is stored using the following layout:
 *
 *    SX_BLESS <flag> <len> <classname> <object>
 *
 * where <flag> indicates whether <len> is stored on 0 or 4 bytes, depending
 * on the high-order bit in flag: if 1, then length follows on 4 bytes.
 * Otherwise, the low order bits give the length, thereby giving a compact
 * representation for class names less than 127 chars long.
 *
 * Each <classname> seen is remembered and indexed, so that the next time
 * an object in the blessed in the same <classname> is stored, the following
 * will be emitted:
 *
 *    SX_IX_BLESS <flag> <index> <object>
 *
 * where <index> is the classname index, stored on 0 or 4 bytes depending
 * on the high-order bit in flag (same encoding as above for <len>).
 */
static void store_blessed(
        pTHX_
	store_cxt_t *store_cxt,
	SV *sv,
	int type,
	HV *pkg)
{
	SV *hook, **hookp;
	I32 classlen;
	char *classname;
	I32 classnum;

	TRACEME(("store_blessed, type %d, class \"%s\"", type, HvNAME_get(pkg)));

	classname = HvNAME_get(pkg);
	classlen = strlen(classname);

	/*
	 * Look for a hook for this blessed SV and redirect to store_hook()
	 * if needed.
	 */

        hookp = hv_fetch(store_cxt->hook, classname, classlen, FALSE);
        if (hookp)
                hook = *hookp;
        else {
                GV *gv = gv_fetchmethod_autoload(pkg, "STORABLE_freeze", FALSE);
                hook = (gv && isGV(gv) ? newRV((SV*) GvCV(gv)) : newSV(0));
                hv_store(store_cxt->hook, classname, classlen, hook, 0);
        }

        if (SvOK(hook)) {
                if (store_hook(aTHX_ store_cxt, sv, type, pkg, hook, (hookp ? 1 : 0)))
                        return;
        }

	/*
	 * This is a blessed SV without any serialization hook.
	 */
	TRACEME(("blessed 0x%"UVxf" in %s, no hook: tagged #%d",
		 PTR2UV(sv), classname, store_cxt->tagnum));

	/*
	 * Determine whether it is the first time we see that class name (in which
	 * case it will be stored in the SX_BLESS form), or whether we already
	 * saw that class name before (in which case the SX_IX_BLESS form will be
	 * used).
	 */

	if (known_class(aTHX_ store_cxt, pkg, &classnum)) {
		TRACEME(("already seen class %s, ID = %d", classname, classnum));
		WRITE_MARK(SX_IX_BLESS);
		if (classnum <= LG_BLESS) {
			WRITE_MARK(classnum);
		} else {
			WRITE_MARK(0x80);
			WRITE_LEN(classnum);
		}
	} else {
		TRACEME(("first time we see class %s, ID = %d", classname, classnum));
		WRITE_MARK(SX_BLESS);
		if (classlen <= LG_BLESS) {
			WRITE_MARK(classlen);
		} else {
			WRITE_MARK(0x80);
			WRITE_LEN(classlen);					/* Don't BER-encode, this should be rare */
		}
		WRITE_BYTES(classname, classlen);				/* Final \0 is omitted */
	}

	/*
	 * Now emit the <object> part.
	 */

	SV_STORE(type)(aTHX_ store_cxt, sv);
}

/*
 * store_other
 *
 * We don't know how to store the item we reached, so return an error condition.
 * (it's probably a GLOB, some CODE reference, etc...)
 *
 * If they defined the 'forgive_me' variable at the Perl level to some
 * true value, then don't croak, just warn, and store a placeholder string
 * instead.
 */
static void store_other(pTHX_ store_cxt_t *store_cxt, SV *sv)
{
	I32 len;
	char buf[80];

	TRACEME(("store_other"));

	/*
	 * Fetch the value from perl only once per store() operation.
	 */

	if (!forgive_me(aTHX))
		CROAK(("Can't store %s items", sv_reftype(sv, FALSE)));

	warn("Can't store item %s(0x%"UVxf")",
             sv_reftype(sv, FALSE), PTR2UV(sv));

	/*
	 * Store placeholder string as a scalar instead...
	 */

	(void) sprintf(buf, "You lost %s(0x%"UVxf")%c", sv_reftype(sv, FALSE),
		       PTR2UV(sv), (char) 0);

	len = strlen(buf);
	WRITE_SCALAR(buf, len);
	TRACEME(("ok (dummy \"%s\", length = %"IVdf")", buf, (IV) len));
}

/***
 *** Store driving routines
 ***/

/*
 * sv_type
 *
 * WARNING: partially duplicates Perl's sv_reftype for speed.
 *
 * Returns the type of the SV, identified by an integer. That integer
 * may then be used to index the dynamic routine dispatch table.
 */
static int sv_type(pTHX_ SV *sv)
{
	switch (SvTYPE(sv)) {
	case SVt_NULL:
#if PERL_VERSION <= 10
	case SVt_IV:
#endif
	case SVt_NV:
		/*
		 * No need to check for ROK, that can't be set here since there
		 * is no field capable of hodling the xrv_rv reference.
		 */
		return svis_SCALAR;
	case SVt_PV:
#if PERL_VERSION <= 10
	case SVt_RV:
#else
	case SVt_IV:
#endif
	case SVt_PVIV:
	case SVt_PVNV:
		/*
		 * Starting from SVt_PV, it is possible to have the ROK flag
		 * set, the pointer to the other SV being either stored in
		 * the xrv_rv (in the case of a pure SVt_RV), or as the
		 * xpv_pv field of an SVt_PV and its heirs.
		 *
		 * However, those SV cannot be magical or they would be an
		 * SVt_PVMG at least.
		 */
		return SvROK(sv) ? svis_REF : svis_SCALAR;
	case SVt_PVMG:
	case SVt_PVLV:		/* Workaround for perl5.004_04 "LVALUE" bug */
		if (SvRMAGICAL(sv) && (mg_find(sv, 'p')))
			return svis_TIED_ITEM;
		/* FALL THROUGH */
#if PERL_VERSION < 9
	case SVt_PVBM:
#endif
		if (SvRMAGICAL(sv) && (mg_find(sv, 'q')))
			return svis_TIED;
		return SvROK(sv) ? svis_REF : svis_SCALAR;
	case SVt_PVAV:
		if (SvRMAGICAL(sv) && (mg_find(sv, 'P')))
			return svis_TIED;
		return svis_ARRAY;
	case SVt_PVHV:
		if (SvRMAGICAL(sv) && (mg_find(sv, 'P')))
			return svis_TIED;
		return svis_HASH;
	case SVt_PVCV:
		return svis_CODE;
#if PERL_VERSION > 8
	/* case SVt_DUMMY: */
#endif
	default:
		break;
	}

	return svis_OTHER;
}

/*
 * store
 *
 * Recursively store objects pointed to by the sv to the specified file.
 *
 * Layout is <content> or SX_OBJECT <tagnum> if we reach an already stored
 * object (one for which storage has started -- it may not be over if we have
 * a self-referenced structure). This data set forms a stored <object>.
 */
static void store(pTHX_ store_cxt_t *store_cxt, SV *sv)
{
	void *tag1;
	int type;
	PTR_TBL_t *pseen = store_cxt->pseen;

	TRACEME(("store (0x%"UVxf")", PTR2UV(sv)));

	/*
	 * If object has already been stored, do not duplicate data.
	 * Simply emit the SX_OBJECT marker followed by its tag data.
	 * The tag is always written in network order.
	 *
	 * NOTA BENE, for 64-bit machines: the "*svh" below does not yield a
	 * real pointer, rather a tag number (watch the insertion code below).
	 * That means it probably safe to assume it is well under the 32-bit limit,
	 * and makes the truncation safe.
	 *		-- RAM, 14/09/1999
	 */

	tag1 = ptr_table_fetch(pseen, sv);
	if (tag1) {
		if (sv != &PL_sv_undef) {
                        I32 tag = LOW_32BITS(((char *)tag1)-1);

                        TRACEME(("object 0x%"UVxf" seen as #%d", PTR2UV(sv), tag));

                        WRITE_MARK(SX_OBJECT);
                        WRITE_I32N(tag);
                        return;
                }

                /* We have seen PL_sv_undef before, but fake it as if
                   we have not.

                   Not the simplest solution to making restricted
                   hashes work on 5.8.0, but it does mean that
                   repeated references to the one true undef will
                   take up less space in the output file.

                   Don't bother decrementing PL_sv_undef ref count as
                   it is an immortal.
                */
        }

        /*
         * Allocate a new tag and associate it with the address of the sv being
         * stored, before recursing...
         */
        store_cxt->tagnum++;
        ptr_table_store(pseen, sv, INT2PTR(SV*, 1 + store_cxt->tagnum));

        /*
         * Store 'sv' and everything beneath it, using appropriate routine.
         * Abort immediately if we get a non-zero status back.
         */

        type = sv_type(aTHX_ sv);

	TRACEME(("storing 0x%"UVxf" tag #%d, type %d...",
		 PTR2UV(sv), store_cxt->tagnum, type));

        if (SvOBJECT(sv))
                store_blessed(aTHX_ store_cxt, sv, type, SvSTASH(sv));
        else 
                SV_STORE(type)(aTHX_ store_cxt, sv);
}

/*
 * magic_write
 *
 * Write magic number and system information into the file.
 * Layout is <magic> <network> [<len> <byteorder> <sizeof int> <sizeof long>
 * <sizeof ptr>] where <len> is the length of the byteorder hexa string.
 * All size and lenghts are written as single characters here.
 *
 * Note that no byte ordering info is emitted when <network> is true, since
 * integers will be emitted in network order in that case.
 */
static void magic_write(pTHX_ store_cxt_t *store_cxt)
{
    /*
     * Starting with 0.6, the "use_network_order" byte flag is also used to
     * indicate the version number of the binary image, encoded in the upper
     * bits. The bit 0 is always used to indicate network order.
     */
    /*
     * Starting with 0.7, a full byte is dedicated to the minor version of
     * the binary format, which is incremented only when new markers are
     * introduced, for instance, but when backward compatibility is preserved.
     */

    /* Make these at compile time.  The WRITE() macro is sufficiently complex
       that it saves about 200 bytes doing it this way and only using it
       once.  */
    static const unsigned char network_file_header[] = {
        MAGICSTR_BYTES,
        (STORABLE_BIN_MAJOR << 1) | 1,
        STORABLE_BIN_WRITE_MINOR
    };
    static const unsigned char file_header[] = {
        MAGICSTR_BYTES,
        (STORABLE_BIN_MAJOR << 1) | 0,
        STORABLE_BIN_WRITE_MINOR,
        /* sizeof the array includes the 0 byte at the end:  */
        (char) sizeof (byteorderstr) - 1,
        BYTEORDER_BYTES,
        (unsigned char) sizeof(int),
	(unsigned char) sizeof(long),
        (unsigned char) sizeof(char *),
	(unsigned char) sizeof(NV)
    };
#ifdef USE_56_INTERWORK_KLUDGE
    static const unsigned char file_header_56[] = {
        MAGICSTR_BYTES,
        (STORABLE_BIN_MAJOR << 1) | 0,
        STORABLE_BIN_WRITE_MINOR,
        /* sizeof the array includes the 0 byte at the end:  */
        (char) sizeof (byteorderstr_56) - 1,
        BYTEORDER_BYTES_56,
        (unsigned char) sizeof(int),
	(unsigned char) sizeof(long),
        (unsigned char) sizeof(char *),
	(unsigned char) sizeof(NV)
    };
#endif
    const unsigned char *header;
    SSize_t length;

    TRACEME(("magic_write on fd=%d", store_cxt->output_fh ? PerlIO_fileno(store_cxt->output_fh) : -1));

    if (store_cxt->netorder) {
        header = network_file_header;
        length = sizeof (network_file_header);
    } else {
#ifdef USE_56_INTERWORK_KLUDGE
        if (SvTRUE(perl_get_sv("Storable::interwork_56_64bit", GV_ADD))) {
            header = file_header_56;
            length = sizeof (file_header_56);
        } else
#endif
        {
            header = file_header;
            length = sizeof (file_header);
        }
    }        

    if (!store_cxt->output_fh) {
        /* sizeof the array includes the 0 byte at the end.  */
        header += sizeof (magicstr) - 1;
        length -= sizeof (magicstr) - 1;
    }        

    WRITE_BYTES((const char*) header, length);

    if (!store_cxt->netorder) {
	TRACEME(("ok (magic_write byteorder = 0x%lx [%d], I%d L%d P%d D%d)",
		 (unsigned long) BYTEORDER, (int) sizeof (byteorderstr) - 1,
		 (int) sizeof(int), (int) sizeof(long),
		 (int) sizeof(char *), (int) sizeof(NV)));
    }
}

static SV *
state_sv(pTHX) {
        SV *sv;
        GV *gv = gv_fetchpvs("Storable::state", GV_ADDMULTI, SVt_PV);
        save_scalar(gv);
        sv = GvSV(gv);
        TRACEME(("state is: %s [gv: 0x%p, sv: 0x%p]", SvPV_nolen(sv), gv, sv));
        return sv;
}

/*
 * do_store
 *
 * One and only one of f and res must be non NULL
 */
static void do_store(pTHX_ PerlIO *f, SV *sv, int network_order, SV **res)
{
        store_cxt_t store_cxt;

	ASSERT(((f || res) && !(f && res)), ("f xor res must be non NULL"));

	TRACEME(("do_store (netorder=%d)", network_order));

	/*
	 * Ensure sv is actually a reference. From perl, we called something
	 * like:
	 *       pstore(aTHX_ FILE, \@array);
	 * so we must get the scalar value behind that reference.
	 */

	if ((SvTYPE(sv) == SVt_PVLV
#if ((PERL_VERSION < 8) || ((PERL_VERSION == 8) && (PERL_SUBVERSION < 1)))
	     || SvTYPE(sv) == SVt_PVMG
#endif
	     ) && SvRMAGICAL(sv) && mg_find(sv, 'p')) {
		mg_get(sv);
	}
	if (!SvROK(sv))
		CROAK(("Not a reference"));
	sv = SvRV(sv);			/* So follow it to know what to store */


	/*
	 * Prepare context and emit headers.
	 */
	init_store_cxt(aTHX_ &store_cxt, f, network_order);
	magic_write(aTHX_ &store_cxt);		/* Emit magic and ILP info */

        sv_setpvs(state_sv(aTHX), "storing");

	/*
	 * Recursively store object...
	 */
	store(aTHX_ &store_cxt, sv);		/* Just do it! */

	/*
	 * If they asked for a memory store and they provided an SV pointer,
	 * make an SV string out of the buffer and fill their pointer.
	 *
	 * When asking for ST_REAL, it's MANDATORY for the caller to provide
	 * an SV, since context cleanup might free the buffer if we did recurse.
	 * (unless caller is dclone(), which is aware of that).
	 */

	if (res)
                *res = SvREFCNT_inc_NN(store_cxt.output_sv);

        sv_setiv(GvSV(gv_fetchpvs("Storable::last_op_in_netorder",  GV_ADDMULTI, SVt_PV)),
                 (store_cxt.netorder > 0 ? 1 : 0));

}

/***
 *** Specific retrieve callbacks.
 ***/

/*
 * retrieve_other
 *
 * Return an error via croak, since it is not possible that we get here
 * under normal conditions, when facing a file produced via pstore().
 */
static SV *retrieve_other(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname)
{
	PERL_UNUSED_ARG(cname);
	if (
		retrieve_cxt->ver_major != STORABLE_BIN_MAJOR &&
		retrieve_cxt->ver_minor != STORABLE_BIN_MINOR
	) {
		CROAK(("Corrupted storable %s (binary v%d.%d), current is v%d.%d",
			retrieve_cxt->input_fh ? "file" : "string",
			retrieve_cxt->ver_major, retrieve_cxt->ver_minor,
			STORABLE_BIN_MAJOR, STORABLE_BIN_MINOR));
	} else {
		CROAK(("Corrupted storable %s (binary v%d.%d)",
			retrieve_cxt->input_fh ? "file" : "string",
			retrieve_cxt->ver_major, retrieve_cxt->ver_minor));
	}

	return (SV *) 0;		/* Make compiler happy */
}

/*
 * retrieve_idx_blessed
 *
 * Layout is SX_IX_BLESS <index> <object> with SX_IX_BLESS already read.
 * <index> can be coded on either 1 or 5 bytes.
 */
static SV *retrieve_idx_blessed(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname)
{
	I32 idx;
	const char *classname;
	SV **sva;

	PERL_UNUSED_ARG(cname);
	TRACEME(("retrieve_idx_blessed (#%d)", retrieve_cxt->tagnum));
	ASSERT(!cname, ("no bless-into class given here, got %s", cname));

        READ_UCHAR(idx);			/* Index coded on a single char? */
	if (idx & 0x80)
		READ_I32(idx);

	/*
	 * Fetch classname in 'aclass'
	 */

	sva = av_fetch(retrieve_cxt->aclass, idx, FALSE);
	if (!sva)
		CROAK(("Class name #%"IVdf" should have been seen already", (IV) idx));

	classname = SvPVX(*sva);	/* We know it's a PV, by construction */

	TRACEME(("class ID %d => %s", idx, classname));

	/*
	 * Retrieve object and bless it.
	 */

	return retrieve(aTHX_ retrieve_cxt, classname);	/* First SV which is SEEN will be blessed */
}

/*
 * retrieve_blessed
 *
 * Layout is SX_BLESS <len> <classname> <object> with SX_BLESS already read.
 * <len> can be coded on either 1 or 5 bytes.
 */
static SV *retrieve_blessed(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname)
{
	I32 len;
	SV *classname;


	PERL_UNUSED_ARG(cname);
	TRACEME(("retrieve_blessed (#%d)", retrieve_cxt->tagnum));
	ASSERT(!cname, ("no bless-into class given here, got %s", cname));

	/*
	 * Decode class name length and read that name.
	 *
	 * Short classnames have two advantages: their length is stored on one
	 * single byte, and the string can be read on the stack.
	 */

	READ_UCHAR(len);			/* Length coded on a single char? */
	if (len & 0x80) READ_I32(len);
	READ_SVPV(classname, len);

	/*
	 * It's a new classname, otherwise it would have been an SX_IX_BLESS.
	 */

	TRACEME(("new class name \"%s\" will bear ID = %d", SvPV_nolen(classname), retrieve_cxt->classnum));

	av_store_safe(aTHX_ retrieve_cxt->aclass, retrieve_cxt->classnum++, classname);

	/*
	 * Retrieve object and bless it.
	 */

	return retrieve(aTHX_ retrieve_cxt, SvPV_nolen(classname));	/* First SV which is SEEN will be blessed */
}

/*
 * retrieve_hook
 *
 * Layout: SX_HOOK <flags> <len> <classname> <len2> <str> [<len3> <object-IDs>]
 * with leading mark already read, as usual.
 *
 * When recursion was involved during serialization of the object, there
 * is an unknown amount of serialized objects after the SX_HOOK mark.  Until
 * we reach a <flags> marker with the recursion bit cleared.
 *
 * If the first <flags> byte contains a type of SHT_EXTRA, then the real type
 * is held in the <extra> byte, and if the object is tied, the serialized
 * magic object comes at the very end:
 *
 *     SX_HOOK <flags> <extra> ... [<len3> <object-IDs>] <magic object>
 *
 * This means the STORABLE_thaw hook will NOT get a tied variable during its
 * processing (since we won't have seen the magic object by the time the hook
 * is called).  See comments below for why it was done that way.
 */
static SV *retrieve_hook(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname)
{
	I32 len, frozen_len, refs_len, i;
        SV *sv, *class_sv, *frozen, *hook, **hookp, *mg_obj;
	unsigned int flags;
	int obj_type, is_thaw, tagnum;
	char mtype = '\0';
	unsigned int extra_type = 0;
        const char *class_pv;
        STRLEN class_len;
        int count;
        dSP;

	PERL_UNUSED_ARG(cname);
	TRACEME(("retrieve_hook (#%d)", retrieve_cxt->tagnum));
	ASSERT(!cname, ("no bless-into class given here, got %s", cname));

	/*
	 * Read flags, which tell us about the type, and whether we need to recurse.
	 */

        READ_UCHAR(flags);

	/*
	 * Create the (empty) object, and mark it as seen.
	 *
	 * This must be done now, because tags are incremented, and during
	 * serialization, the object tag was affected before recursion could
	 * take place.
	 */

	obj_type = flags & SHF_TYPE_MASK;
	switch (obj_type) {
	case SHT_SCALAR:
		sv = newSV(0);
		break;
	case SHT_ARRAY:
		sv = (SV *) newAV();
		break;
	case SHT_HASH:
		sv = (SV *) newHV();
		break;
	case SHT_EXTRA:
		/*
		 * Read <extra> flag to know the type of the object.
		 * Record associated magic type for later.
		 */
		READ_UCHAR(extra_type);
		switch (extra_type) {
		case SHT_TSCALAR:
			sv = newSV(0);
			mtype = 'q';
			break;
		case SHT_TARRAY:
			sv = (SV *) newAV();
			mtype = 'P';
			break;
		case SHT_THASH:
			sv = (SV *) newHV();
			mtype = 'P';
			break;
		default:
                        return retrieve_other(aTHX_ retrieve_cxt, 0);	/* Let it croak */
		}
		break;
	default:
		return retrieve_other(aTHX_ retrieve_cxt, 0);		/* Let it croak */
	}

        tagnum = retrieve_cxt->tagnum;
	SEEN_no_inc(sv, 0); /* Don't bless as we don't know the class yet */

	/*
	 * Whilst flags tell us to recurse, do so.
	 *
	 * We don't need to remember the addresses returned by retrieval, because
	 * all the references will be obtained through indirection via the object
	 * tags in the object-ID list.
	 *
	 * We need to decrement the reference count for these objects
	 * because, if the user doesn't save a reference to them in the hook,
	 * they must be freed when this context is cleaned.
	 */

	while (flags & SHF_NEED_RECURSE) {
                SV *rv;
		TRACEME(("retrieve_hook recursing..."));
		rv = retrieve(aTHX_ retrieve_cxt, 0);
                ASSERT(rv, ("retrieve returns non NULL"));
		SvREFCNT_dec(rv);
		TRACEME(("retrieve_hook back with rv=0x%"UVxf,
			 PTR2UV(rv)));
		READ_UCHAR(flags);
	}

	if (flags & SHF_IDX_CLASSNAME) {
		SV **sva;
		I32 idx;

		/*
		 * Fetch index from 'aclass'
		 */
		READ_VARINT(flags & SHF_LARGE_CLASSLEN, idx);
		sva = av_fetch(retrieve_cxt->aclass, idx, FALSE);
		if (!sva)
			CROAK(("Class name #%"IVdf" should have been seen already",
				(IV) idx));

                class_sv = *sva;
		TRACEME(("class ID %d => %s", idx, class_pv));

	} else {
		READ_VARINT(flags & SHF_LARGE_CLASSLEN, len);
		READ_SVPV(class_sv, len);

		/*
		 * Record new classname.
		 */

		av_store_safe(aTHX_ retrieve_cxt->aclass, retrieve_cxt->classnum++, class_sv);
	}
        ASSERT((class_sv && SvPOK(class_sv)), ("class_sv has a PV"));
        class_pv = SvPV(class_sv, class_len);

	/*
	 * Bless the object and look up the STORABLE_attach and STORABLE_thaw hooks.
	 */

        BLESS(sv, class_pv);

        hookp = hv_fetch(retrieve_cxt->hook, class_pv, class_len, FALSE);
        if (hookp) {
                hook = *hookp;
                ASSERT((hook && SvROK(hook) && (SvTYPE(SvRV(hook)) == SVt_PVCV)), ("hook is a CV"));
                is_thaw = (SvMAGICAL(hook) && mg_find(hook, PERL_MAGIC_ext) ? 0 : 1);
        }
        else {
                int load;
                for (load = 0; load < 2; load++) {
                        if (load) {
                                TRACEME(("Going to load module '%s'", class_pv));
                                load_module(PERL_LOADMOD_NOIMPORT, newSVsv(class_sv), Nullsv);
                        }
                        for (is_thaw = 0; is_thaw < 2; is_thaw++) {
                                const char *method = (is_thaw ? "STORABLE_thaw" : "STORABLE_attach");
                                GV *gv = gv_fetchmethod_autoload(gv_stashsv(class_sv, GV_ADD),
                                                                 method, FALSE);
                                if (gv && isGV(gv)) {
                                        hook = newRV((SV *)GvCV(gv));
                                        /* we use a magic entry as a marker to distinguish between
                                         * STORABLE_thaw and STORABLE_attach */ 
                                        if (!is_thaw)
                                                sv_magic(hook, NULL, PERL_MAGIC_ext, method, 0);
                                        hv_store_ent(retrieve_cxt->hook, class_sv, hook, 0);
                                        TRACEME(("%s::STORABLE_%s method found", class_pv,
                                                 (is_thaw ? "thaw": "attach")));
                                        goto hook_found;
                                }
                                TRACEME(("No %s defined for objects of class %s", method, class_pv));
                        }
                }
                CROAK(("No STORABLE_attach or STORABLE_thaw method defined for objects of class %s "
                       "(even after requiring it)", class_pv));
        }
hook_found:

	TRACEME(("class name: %s", class_pv));

	/*
	 * Decode user-frozen string length and read it in an SV.
	 */
        READ_VARINT(flags & SHF_LARGE_STRLEN, frozen_len);
	READ_SVPV(frozen, frozen_len);
        sv_2mortal(frozen);

	TRACEME(("frozen string: %d bytes", frozen_len));

	/*
	 * Decode object-ID list length, if present.
	 */
	if (flags & SHF_HAS_LIST)
		READ_VARINT(flags & SHF_LARGE_LISTLEN, refs_len);
        else
                refs_len = 0;


	TRACEME(("has %d object IDs to link", refs_len));

        ASSERT((SvROK(hook) && (SvTYPE(SvRV(hook)) == SVt_PVCV)), ("hook is a CV"));

        /*
         * Call the hook as:
         *
         *   $class->STORABLE_attach($clonning, $frozen);
         *
         * or
         *
         *   $object->STORABLE_thaw($cloning, $frozen, @refs);
         * 
         * where $object is our blessed (empty) object, $cloning is a boolean
         * telling whether we're running a deep clone, $frozen is the frozen
         * string the user gave us in his serializing hook, and @refs, which may
         * be empty, is the list of extra references he returned along for us
         * to serialize.
         *
         * In effect, the hook is an alternate creation routine for the class,
         * the object itself being already created by the runtime.
         */

        TRACEME(("calling %s::STORABLE_%s (%"IVdf" args)",
                 class_pv, (is_thaw ? "thaw" : "attach"), refs_len));

        ENTER;
        SAVETMPS;
        PUSHMARK(sp);
        EXTEND(sp, refs_len + 3);
        if (is_thaw)
                PUSHs(sv_2mortal(newRV(sv)));
        else {
                if (refs_len)
                        CROAK(("STORABLE_attach called with unexpected references"));
                PUSHs(sv_mortalcopy(class_sv));
        }

        PUSHs(retrieve_cxt->cloning ? &PL_sv_yes : &PL_sv_no); /* clonning arg */
        PUSHs(frozen);
        for (i = 0; i < refs_len; i++) {
                /*
                 * We read object tags and we can convert them into SV* on the fly
                 * because we know all the references listed in there (as tags)
                 * have been already serialized, hence we have a valid correspondence
                 * between each of those tags and the recreated SV.
                 */
                I32 tag;
                SV **argp, *arg;
                READ_I32N(tag);
                argp = av_fetch(retrieve_cxt->aseen, tag, FALSE);
                if (argp)
                        arg = *argp;
                else if (tag == retrieve_cxt->where_is_undef)
                        arg = &PL_sv_undef;
                else
                        CROAK(("Object #0x%"UVxf" should have been retrieved already [1]",
                               (UV) tag));
                PUSHs(sv_2mortal(newRV(arg)));
        }
        PUTBACK;
        count = call_sv(hook, G_SCALAR);
        ASSERT(count == 1, ("call_sv(..., G_SCALAR) = %d == 1", count));
        
        SPAGAIN;
        if (!is_thaw) {
                SV *rv = POPs;
                if (!(SvROK(rv) && sv_derived_from_sv(rv, class_sv, 0)))
                        CROAK(("STORABLE_attach did not return a %s object", class_pv));
                sv = SvRV(rv);
                av_store(retrieve_cxt->aseen, tagnum, SvREFCNT_inc_NN(sv));
        }

        PUTBACK;
        FREETMPS;
        LEAVE;

	if (!extra_type)
                return SvREFCNT_inc_NN(sv);

	/*
	 * If we had an <extra> type, then the object was not as simple, and
	 * we need to restore extra magic now.
	 */

	TRACEME(("retrieving magic object for 0x%"UVxf"...", PTR2UV(sv)));

	mg_obj = retrieve(aTHX_ retrieve_cxt, 0);		/* Retrieve <magic object> */
        ASSERT(mg_obj, ("retrieve returns non NULL"));
        sv_2mortal(mg_obj);

	TRACEME(("restoring the magic object 0x%"UVxf" part of 0x%"UVxf,
		PTR2UV(mg_obj), PTR2UV(sv)));

	switch (extra_type) {
	case SHT_TSCALAR:
		sv_upgrade(sv, SVt_PVMG);
		break;
	case SHT_TARRAY:
		sv_upgrade(sv, SVt_PVAV);
		AvREAL_off((AV *)sv);
		break;
	case SHT_THASH:
		sv_upgrade(sv, SVt_PVHV);
		break;
	default:
		CROAK(("Forgot to deal with extra type %d", extra_type));
		break;
	}

	/*
	 * Adding the magic only now, well after the STORABLE_thaw hook was called
	 * means the hook cannot know it deals with an object whose variable is
	 * tied.  But this is happening when retrieving $o in the following case:
	 *
	 *	my %h;
	 *  tie %h, 'FOO';
	 *	my $o = bless \%h, 'BAR';
	 *
	 * The 'BAR' class is NOT the one where %h is tied into.  Therefore, as
	 * far as the 'BAR' class is concerned, the fact that %h is not a REAL
	 * hash but a tied one should not matter at all, and remain transparent.
	 * This means the magic must be restored by Storable AFTER the hook is
	 * called.
	 *
	 * That looks very reasonable to me, but then I've come up with this
	 * after a bug report from David Nesting, who was trying to store such
	 * an object and caused Storable to fail.  And unfortunately, it was
	 * also the easiest way to retrofit support for blessed ref to tied objects
	 * into the existing design.  -- RAM, 17/02/2001
	 */

	sv_magic(sv, mg_obj, mtype, (char *)NULL, 0);
	return SvREFCNT_inc_NN(sv);
}

/*
 * retrieve_ref
 *
 * Retrieve reference to some other scalar.
 * Layout is SX_REF <object>, with SX_REF already read.
 */
static SV *retrieve_ref(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname)
{
	SV *rv;
	SV *sv;

	TRACEME(("retrieve_ref (#%d)", retrieve_cxt->tagnum));

	/*
	 * We need to create the SV that holds the reference to the yet-to-retrieve
	 * object now, so that we may record the address in the seen table.
	 * Otherwise, if the object to retrieve references us, we won't be able
	 * to resolve the SX_OBJECT we'll see at that point! Hence we cannot
	 * do the retrieve first and use rv = newRV(sv) since it will be too late
	 * for SEEN() recording.
	 */

	rv = newSV(0);
	SEEN_no_inc(rv, cname);
	sv = retrieve(aTHX_ retrieve_cxt, 0);	/* Retrieve <object> */
        ASSERT(sv, ("retrieve returns non NULL"));

	/*
	 * WARNING: breaks RV encapsulation.
	 *
	 * Now for the tricky part. We have to upgrade our existing SV, so that
	 * it is now an RV on sv... Again, we cheat by duplicating the code
	 * held in newSVrv(), since we already got our SV from retrieve().
	 */

	if (cname) {
		/* No need to do anything, as rv will already be PVMG.  */
		assert (SvTYPE(rv) == SVt_RV || SvTYPE(rv) >= SVt_PV);
	} else {
		sv_upgrade(rv, SVt_RV);
	}

	SvRV_set(rv, sv);				/* $rv = \$sv */
	SvROK_on(rv);

	TRACEME(("ok (retrieve_ref at 0x%"UVxf")", PTR2UV(rv)));

	return SvREFCNT_inc_NN(rv);
}

/*
 * retrieve_weakref
 *
 * Retrieve weak reference to some other scalar.
 * Layout is SX_WEAKREF <object>, with SX_WEAKREF already read.
 */
static SV *retrieve_weakref(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname)
{
#ifdef SvWEAKREF
	SV *sv;
	TRACEME(("retrieve_weakref (#%d)", retrieve_cxt->tagnum));
	sv = retrieve_ref(aTHX_ retrieve_cxt, cname);
        ASSERT(sv, ("retrieve_ref returned non NULL"));
        sv_rvweaken(sv);
	return sv;
#else
        WEAKREF_CROAK();
        return Nullsv;
#endif
}

/*
 * retrieve_overloaded
 *
 * Retrieve reference to some other scalar with overloading.
 * Layout is SX_OVERLOAD <object>, with SX_OVERLOAD already read.
 */
static SV *retrieve_overloaded(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname)
{
	SV *rv;
	SV *sv;
	HV *stash;

	TRACEME(("retrieve_overloaded (#%d)", retrieve_cxt->tagnum));

	/*
	 * Same code as retrieve_ref(), duplicated to avoid extra call.
	 */

	rv = newSV(0);
	SEEN_no_inc(rv, cname);
	sv = retrieve(aTHX_ retrieve_cxt, 0);	/* Retrieve <object> */
        ASSERT(sv, ("retrieve returns non NULL"));

	/*
	 * WARNING: breaks RV encapsulation.
	 */
	SvUPGRADE(rv, SVt_RV);
	SvRV_set(rv, sv);				/* $rv = \$sv */
	SvROK_on(rv);

	/*
	 * Restore overloading magic.
	 */
	stash = SvTYPE(sv) ? (HV *) SvSTASH (sv) : 0;
	if (!stash) {
		CROAK(("Cannot restore overloading on %s(0x%"UVxf
		       ") (package <unknown>)",
		       sv_reftype(sv, FALSE),
		       PTR2UV(sv)));
	}
	if (!Gv_AMG(stash)) {
	        const char *package = HvNAME_get(stash);
		TRACEME(("No overloading defined for package %s", package));
		TRACEME(("Going to load module '%s'", package));
		load_module(PERL_LOADMOD_NOIMPORT, newSVpv(package, 0), Nullsv);
		if (!Gv_AMG(stash)) {
			CROAK(("Cannot restore overloading on %s(0x%"UVxf
			       ") (package %s) (even after a \"require %s;\")",
			       sv_reftype(sv, FALSE),
			       PTR2UV(sv),
			       package, package));
		}
	}

	SvAMAGIC_on(rv);

	TRACEME(("ok (retrieve_overloaded at 0x%"UVxf")", PTR2UV(rv)));

	return SvREFCNT_inc_NN(rv);
}

/*
 * retrieve_weakoverloaded
 *
 * Retrieve weak overloaded reference to some other scalar.
 * Layout is SX_WEAKOVERLOADED <object>, with SX_WEAKOVERLOADED already read.
 */
static SV *retrieve_weakoverloaded(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname)
{
#ifdef SvWEAKREF
	SV *sv;
	TRACEME(("retrieve_weakoverloaded (#%d)", retrieve_cxt->tagnum));
	sv = retrieve_overloaded(aTHX_ retrieve_cxt, cname);
        ASSERT(sv, ("retrieve_overloaded returns non NULL"));
        sv_rvweaken(sv);
        return sv;
#else
        WEAKREF_CROAK();
        return Nullsv;        
#endif
}

static SV *retrieve_tied_any(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname, SV *tv, int how) {
        SV *sv;
	TRACEME(("retrieve_tied_any (#%d, SV type %d)", retrieve_cxt->tagnum, SvTYPE(tv)));

	SEEN_no_inc((SV*)tv, cname);

        sv = retrieve(aTHX_ retrieve_cxt, 0);		/* Retrieve <object> */
        ASSERT(sv, ("retrieve returns non NULL"));
	sv_magic(tv, (SvTYPE(sv) == SVt_NULL ? Nullsv : sv), how, (char *)NULL, 0);
	SvREFCNT_dec(sv);			/* Undo refcnt inc from sv_magic() */
        
	TRACEME(("ok (retrieve tied hash, array or scalar at 0x%"UVxf")", PTR2UV(tv)));

	return SvREFCNT_inc_NN(tv);
}

/*
 * retrieve_tied_array
 *
 * Retrieve tied array
 * Layout is SX_TIED_ARRAY <object>, with SX_TIED_ARRAY already read.
 */
static SV *retrieve_tied_array(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname)
{
	AV *av = newAV();
	AvREAL_off(av);
        return retrieve_tied_any(aTHX_ retrieve_cxt, cname, (SV*)av, PERL_MAGIC_tied);
}

/*
 * retrieve_tied_hash
 *
 * Retrieve tied hash
 * Layout is SX_TIED_HASH <object>, with SX_TIED_HASH already read.
 */
static SV *retrieve_tied_hash(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname)
{
        return retrieve_tied_any(aTHX_ retrieve_cxt, cname, (SV*)newHV(), PERL_MAGIC_tied);
}

/*
 * retrieve_tied_scalar
 *
 * Retrieve tied scalar
 * Layout is SX_TIED_SCALAR <object>, with SX_TIED_SCALAR already read.
 */
static SV *retrieve_tied_scalar(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname)
{
        return retrieve_tied_any(aTHX_ retrieve_cxt, cname, newSV(0), PERL_MAGIC_tiedscalar);
}

/*
 * retrieve_tied_key
 *
 * Retrieve reference to value in a tied hash.
 * Layout is SX_TIED_KEY <object> <key>, with SX_TIED_KEY already read.
 */
static SV *retrieve_tied_key(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname)
{
	SV *tv;
	SV *sv;
	SV *key;

	TRACEME(("retrieve_tied_key (#%d)", retrieve_cxt->tagnum));

	tv = newSV(0);
	SEEN_no_inc(tv, cname);

        /* Retrieve <object>, mortalize it because retrieving the key
         * may croak */
	sv = sv_2mortal(retrieve(aTHX_ retrieve_cxt, 0));
        ASSERT(sv, ("retrieve returns non NULL"));
        
	key = retrieve(aTHX_ retrieve_cxt, 0);		/* Retrieve <key> */
        ASSERT(key, ("retrieve returns non NULL"));

	sv_magic(tv, sv, 'p', (char *)key, HEf_SVKEY);
	SvREFCNT_dec(key);			/* Undo refcnt inc from sv_magic() */

	return SvREFCNT_inc_NN(tv);
}

/*
 * retrieve_tied_idx
 *
 * Retrieve reference to value in a tied array.
 * Layout is SX_TIED_IDX <object> <idx>, with SX_TIED_IDX already read.
 */
static SV *retrieve_tied_idx(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname)
{
	SV *tv;
	SV *sv;
	I32 idx;

	TRACEME(("retrieve_tied_idx (#%d)", retrieve_cxt->tagnum));

	tv = newSV(0);
	SEEN_no_inc(tv, cname);

        /* Retrieve <object>, mortalize it because retrieving the index
         * may croak */
	sv = sv_2mortal(retrieve(aTHX_ retrieve_cxt, 0));
        ASSERT(sv, ("retrieve returns non NULL"));

	READ_I32(idx);					/* Retrieve <idx> */

	sv_magic(tv, sv, 'p', (char *)NULL, idx);

	return SvREFCNT_inc_NN(tv);
}

static SV *retrieve_scalar_any(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname, IV len, int utf8) {
        SV *sv;
	TRACEME(("retrieve_scalar_any (#%d), len = %"IVdf, retrieve_cxt->tagnum, (IV) len));

	READ_SVPV(sv, len);
	SEEN_no_inc(sv, cname);	/* Associate this new scalar with tag "tagnum" */
        
	TRACEME(("scalar len %"IVdf" utf8 %d '%s'", (IV) len, utf8, SvPVX(sv)));
	TRACEME(("ok (retrieve_scalar_any at 0x%"UVxf")", PTR2UV(sv)));

        if (utf8) {
#ifdef HAS_UTF8_SCALARS
                SvUTF8_on(sv);
#else
                if (retrieve_cxt->use_bytes < 0)
                        retrieve_cxt->use_bytes
                                = (SvTRUE(perl_get_sv("Storable::drop_utf8", GV_ADD))
                                   ? 1 : 0);
                if (retrieve_cxt->use_bytes == 0)
                        UTF8_CROAK();
#endif
        }
	return SvREFCNT_inc_NN(sv);
}

/*
 * retrieve_lscalar
 *
 * Retrieve defined long (string) scalar.
 *
 * Layout is SX_LSCALAR <length> <data>, with SX_LSCALAR already read.
 * The scalar is "long" in that <length> is larger than LG_SCALAR so it
 * was not stored on a single byte.
 */
static SV *retrieve_lscalar(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname)
{
	I32 len;
	READ_I32(len);
        return retrieve_scalar_any(aTHX_ retrieve_cxt, cname, len, 0);
}

/*
 * retrieve_scalar
 *
 * Retrieve defined short (string) scalar.
 *
 * Layout is SX_SCALAR <length> <data>, with SX_SCALAR already read.
 * The scalar is "short" so <length> is single byte. If it is 0, there
 * is no <data> section.
 */
static SV *retrieve_scalar(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname)
{
	int len;
	READ_UCHAR(len);
        return retrieve_scalar_any(aTHX_ retrieve_cxt, cname, len, 0);
}

/*
 * retrieve_utf8str
 *
 * Like retrieve_scalar(), but tag result as utf8.
 * If we're retrieving UTF8 data in a non-UTF8 perl, croaks.
 */
static SV *retrieve_utf8str(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname)
{
        int len;
        READ_UCHAR(len);
        return retrieve_scalar_any(aTHX_ retrieve_cxt, cname, len, 1);
}

/*
 * retrieve_lutf8str
 *
 * Like retrieve_lscalar(), but tag result as utf8.
 * If we're retrieving UTF8 data in a non-UTF8 perl, croaks.
 */
static SV *retrieve_lutf8str(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname)
{
        I32 len;
	READ_I32(len);
        return retrieve_scalar_any(aTHX_ retrieve_cxt, cname, len, 1);
}

static SV *retrieve_vstring_any(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname, int l) {
#ifdef SvVOK
	SV *sv, *s;
        I32 len;
        READ_VARINT(l, len);
        READ_SVPV(s, len);
        sv_2mortal(s);

	TRACEME(("retrieve_vstring (#%d), len = %d", retrieve_cxt->tagnum, len));

	sv = retrieve(aTHX_ retrieve_cxt, cname);
        ASSERT(sv, ("retrieve returns non NULL"));
        sv_magic(sv, NULL, PERL_MAGIC_vstring, SvPV_nolen(s), len);

        /* 5.10.0 and earlier seem to need this */
        SvRMAGICAL_on(sv);

	TRACEME(("ok (retrieve_vstring_any at 0x%"UVxf")", PTR2UV(sv)));
	return sv;
#else
	VSTRING_CROAK();
	return Nullsv;
#endif
}

/*
 * retrieve_vstring
 *
 * Retrieve a vstring, and then retrieve the stringy scalar following it,
 * attaching the vstring to the scalar via magic.
 * If we're retrieving a vstring in a perl without vstring magic, croaks.
 *
 * The vstring layout mirrors an SX_SCALAR string:
 * SX_VSTRING <length> <data> with SX_VSTRING already read.
 */
static SV *retrieve_vstring(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname) {
        return retrieve_vstring_any(aTHX_ retrieve_cxt, cname, 0);
}

/*
 * retrieve_lvstring
 *
 * Like retrieve_vstring, but for longer vstrings.
 */
static SV *retrieve_lvstring(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname) {
        return retrieve_vstring_any(aTHX_ retrieve_cxt, cname, 1);
}

/*
 * retrieve_integer
 *
 * Retrieve defined integer.
 * Layout is SX_INTEGER <data>, whith SX_INTEGER already read.
 */
static SV *retrieve_integer(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname)
{
	SV *sv;
	IV iv;

	TRACEME(("retrieve_integer (#%d)", retrieve_cxt->tagnum));

	READ_BYTES(&iv, sizeof(iv));
	sv = newSViv(iv);
	SEEN(sv, cname);	/* Associate this new scalar with tag "tagnum" */

	TRACEME(("integer %"IVdf, iv));
	TRACEME(("ok (retrieve_integer at 0x%"UVxf")", PTR2UV(sv)));

	return sv;
}

/*
 * retrieve_netint
 *
 * Retrieve defined integer in network order.
 * Layout is SX_NETINT <data>, whith SX_NETINT already read.
 */
static SV *retrieve_netint(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname)
{
	SV *sv;
	I32 i32;

	TRACEME(("retrieve_netint (#%d)", retrieve_cxt->tagnum));

	READ_I32N(i32);
	sv = newSViv(i32);
	TRACEME(("network integer %d", i32));
	SEEN(sv, cname);	/* Associate this new scalar with tag "tagnum" */

	TRACEME(("ok (retrieve_netint at 0x%"UVxf")", PTR2UV(sv)));

	return sv;
}

/*
 * retrieve_double
 *
 * Retrieve defined double.
 * Layout is SX_DOUBLE <data>, whith SX_DOUBLE already read.
 */
static SV *retrieve_double(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname)
{
	SV *sv;
	NV nv;

	TRACEME(("retrieve_double (#%d)", retrieve_cxt->tagnum));

	READ_BYTES(&nv, sizeof(nv));
	sv = newSVnv(nv);
	SEEN(sv, cname);	/* Associate this new scalar with tag "tagnum" */

	TRACEME(("double %"NVff, nv));
	TRACEME(("ok (retrieve_double at 0x%"UVxf")", PTR2UV(sv)));

	return sv;
}

/*
 * retrieve_byte
 *
 * Retrieve defined byte (small integer within the [-128, +127] range).
 * Layout is SX_BYTE <data>, whith SX_BYTE already read.
 */
static SV *retrieve_byte(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname)
{
	SV *sv;
	int siv;
	signed char tmp;	/* Workaround for AIX cc bug --H.Merijn Brand */

	TRACEME(("retrieve_byte (#%d)", retrieve_cxt->tagnum));

	READ_UCHAR(siv);
	TRACEME(("small integer read as %d", (unsigned char) siv));
	tmp = (unsigned char) siv - 128;
	sv = newSViv(tmp);
	SEEN(sv, cname);	/* Associate this new scalar with tag "tagnum" */

	TRACEME(("byte %d", tmp));
	TRACEME(("ok (retrieve_byte at 0x%"UVxf")", PTR2UV(sv)));

	return sv;
}

/*
 * retrieve_undef
 *
 * Return the undefined value.
 */
static SV *retrieve_undef(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname)
{
	SV* sv;

	TRACEME(("retrieve_undef"));

	sv = newSV(0);
	SEEN(sv, cname);

	return sv;
}

/*
 * retrieve_sv_undef
 *
 * Return the immortal undefined value.
 */
static SV *retrieve_sv_undef(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname)
{
	SV *sv = &PL_sv_undef;

	TRACEME(("retrieve_sv_undef"));

	/* Special case PL_sv_undef, as av_fetch uses it internally to mark
	   deleted elements, and will return NULL (fetch failed) whenever it
	   is fetched.  */
	if (retrieve_cxt->where_is_undef == -1) {
		retrieve_cxt->where_is_undef = retrieve_cxt->tagnum;
	}
	SEEN(sv, cname);
	return sv;
}

/*
 * retrieve_sv_yes
 *
 * Return the immortal yes value.
 */
static SV *retrieve_sv_yes(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname)
{
	SV *sv = &PL_sv_yes;

	TRACEME(("retrieve_sv_yes"));

	SEEN(sv, cname);
	return sv;
}

/*
 * retrieve_sv_no
 *
 * Return the immortal no value.
 */
static SV *retrieve_sv_no(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname)
{
	SV *sv = &PL_sv_no;

	TRACEME(("retrieve_sv_no"));

	SEEN(sv, cname);
	return sv;
}

/*
 * retrieve_array
 *
 * Retrieve a whole array.
 * Layout is SX_ARRAY <size> followed by each item, in increasing index order.
 * Each item is stored as <object>.
 *
 * When we come here, SX_ARRAY has been read already.
 */
static SV *retrieve_array(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname)
{
	I32 len;
	I32 i;
	AV *av;
	SV *sv;

	TRACEME(("retrieve_array (#%d)", retrieve_cxt->tagnum));

	/*
	 * Read length, and allocate array, then pre-extend it.
	 */

	READ_I32(len);
	TRACEME(("size = %d", len));
	av = newAV();
	SEEN_no_inc(av, cname);
        av_extend(av, len);
	for (i = 0; i < len; i++) {
		TRACEME(("(#%d) item", i));
		sv = retrieve(aTHX_ retrieve_cxt, 0);			/* Retrieve item */
                ASSERT(sv, ("retrieve returns not NULL"));
                av_store_safe(aTHX_ av, i, sv);
	}

	TRACEME(("ok (retrieve_array at 0x%"UVxf")", PTR2UV(av)));
	return SvREFCNT_inc_NN((SV*)av);
}

static SV *retrieve_hash_any(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname, int with_flags) {
    dVAR;
    I32 len;
    I32 size;
    I32 i;
    HV *hv;
    SV *sv;
    int hash_flags;

    TRACEME(("retrieve_flag_hash (#%d)", retrieve_cxt->tagnum));
    if (with_flags) {
            READ_UCHAR(hash_flags);
#ifndef HAS_RESTRICTED_HASHES
            if ((hash_flags & SHV_RESTRICTED) && !downgrade_restricted(aTHX))
                    CROAK(("Cannot retrieve restricted hash"));
#endif
    }
    else
            hash_flags = 0;




    /*
     * Read length, allocate table.
     */
    READ_I32(len);
    TRACEME(("size = %d, flags = %d", len, hash_flags));
    hv = newHV();
    SEEN_no_inc(hv, cname);
    if (len) {
            hv_ksplit(hv, len + 1);		/* pre-extend hash to save multiple splits */

            /*
             * Now get each key/value pair in turn...
             */

            for (i = 0; i < len; i++) {
                    int store_flags = 0;
                    const char *kbuf;
                    /*
                     * Get value first.
                     */

                    TRACEME(("(#%d) value", i));
                    sv = retrieve(aTHX_ retrieve_cxt, 0);
                    ASSERT(sv, ("retrieve returns non NULL"));
                    SvREFCNT_dec(sv); /* key retrieving may fail */

                    if (with_flags) {
                            int flags;
                            READ_UCHAR(flags);
#ifdef HAS_RESTRICTED_HASHES
                            if ((hash_flags & SHV_RESTRICTED) && (flags & SHV_K_LOCKED))
                                    SvREADONLY_on(sv);
#endif
                            if (flags & SHV_K_ISSV) {
                                    /* XXX you can't set a placeholder with an SV key.
                                       Then again, you can't get an SV key.
                                       Without messing around beyond what the API is supposed to do.
                                    */
                                    SV *keysv;
                                    TRACEME(("(#%d) keysv, flags=%d", i, flags));
                                    keysv = retrieve(aTHX_ retrieve_cxt, 0);
                                    ASSERT(keysv, ("retrieve returns non NULL"));

                                    hv_store_ent(hv, keysv, SvREFCNT_inc_NN(sv), 0);

                                    continue;
                            }

                            /*
                             * Get key.
                             * Since we're reading into kbuf, we must ensure we're not
                             * recursing between the read and the hv_store() where it's used.
                             * Hence the key comes after the value.
                             */

                            if (flags & SHV_K_PLACEHOLDER) {
                                    sv = &PL_sv_placeholder;
                                    store_flags |= HVhek_PLACEHOLD;
                            }
                            if (flags & SHV_K_UTF8) {
#ifdef HAS_UTF8_HASHES
                                    store_flags |= HVhek_UTF8;
#else
                                    if (retrieve_cxt->use_bytes < 0)
                                            retrieve_cxt->use_bytes
                                                    = (SvTRUE(perl_get_sv("Storable::drop_utf8", GV_ADD))
                                                       ? 1 : 0);
                                    if (retrieve_cxt->use_bytes == 0)
                                            UTF8_CROAK();
#endif
                            }
#ifdef HAS_UTF8_HASHES
                            if (flags & SHV_K_WASUTF8)
                                    store_flags |= HVhek_WASUTF8;
#endif
                    }
                    READ_I32(size);						/* Get key size */
                    READ_KEY(kbuf, size);
                    TRACEME(("(#%d) key '%s' store_flags %X", i, kbuf, store_flags));

                    /*
                     * Enter key/value pair into hash table.
                     */

#ifdef HAS_RESTRICTED_HASHES
                    if (!hv_store_flags(hv, kbuf, size, sv, 0, store_flags) )
                            Perl_croak(aTHX_ "Internal error: hv_store_flags failed");
                    SvREFCNT_inc_NN(sv);
#else
                    if (!(store_flags & HVhek_PLACEHOLD))
                            hv_store_safe(aTHX_ hv, kbuf, size, SvREFCNT_inc_NN(sv));
#endif
            }
    }
#ifdef HAS_RESTRICTED_HASHES
    if (hash_flags & SHV_RESTRICTED)
            SvREADONLY_on(hv);
#endif

    TRACEME(("ok (retrieve_hash at 0x%"UVxf")", PTR2UV(hv)));

    return SvREFCNT_inc_NN((SV *) hv);
}

/*
 * retrieve_hash
 *
 * Retrieve a whole hash table.
 * Layout is SX_HASH <size> followed by each key/value pair, in random order.
 * Keys are stored as <length> <data>, the <data> section being omitted
 * if length is 0.
 * Values are stored as <object>.
 *
 * When we come here, SX_HASH has been read already.
 */
static SV *retrieve_hash(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname) {
        return retrieve_hash_any(aTHX_ retrieve_cxt, cname, 0);
}

/*
 * retrieve_flag_hash
 *
 * Retrieve a whole hash table with flags.
 * Layout is SX_HASH <flags> <size> followed by each flags+key+value trio, in random order.
 * Keys are stored as <length> <data>, the <data> section being omitted
 * if length is 0.
 * Values are stored as <object>.
 *
 * When we come here, SX_FLAG_HASH has been read already.
 */

static SV *retrieve_flag_hash(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname) {
        return retrieve_hash_any(aTHX_ retrieve_cxt, cname, 1);
}

/*
 * retrieve_code
 *
 * Return a code reference.
 */
static SV *retrieve_code(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname)
{
	int type, tagnum;
	SV *text, *sub;

	TRACEME(("retrieve_code (#%d)", retrieve_cxt->tagnum));

	/*
	 *  Insert dummy SV in the aseen array so that we don't screw
	 *  up the tag numbers.  We would just make the internal
	 *  scalar an untagged item in the stream, but
	 *  retrieve_scalar() calls SEEN().  So we just increase the
	 *  tag number.
	 */
	tagnum = retrieve_cxt->tagnum;
	sub = newSV(0);
	SEEN_no_inc(sub, cname);

	/*
	 * Retrieve the source of the code reference
	 * as a small or large scalar
	 */

	READ_UCHAR(type);
	switch (type) {
	case SX_SCALAR:
		text = retrieve_scalar(aTHX_ retrieve_cxt, cname);
		break;
	case SX_LSCALAR:
		text = retrieve_lscalar(aTHX_ retrieve_cxt, cname);
		break;
	case SX_UTF8STR:
		text = retrieve_utf8str(aTHX_ retrieve_cxt, cname);
		break;
	case SX_LUTF8STR:
		text = retrieve_lutf8str(aTHX_ retrieve_cxt, cname);
		break;
	default:
		CROAK(("Unexpected type %d in retrieve_code\n", type));
	}

	/*
	 * prepend "sub " to the source
	 */

	sv_setpvn(sub, "sub ", 4);
	if (SvUTF8(text))
                SvUTF8_on(sub);
	sv_catpv(sub, SvPV_nolen(text)); /* XXX no sv_catsv! */
	SvREFCNT_dec(text);

        ASSERT(retrieve_cxt->eval, ("retrieve_cxt->eval is not NULL"));
	if (SvTRUE(retrieve_cxt->eval)) {
#if PERL_VERSION < 6
                CROAK(("retrieve_code does not work with perl 5.005 or less\n"));
#else
                /*
                 * evaluate the source to a code reference and use the CV value
                 */

                int count;
                SV *cv;
                dSP;

                ENTER;
                SAVETMPS;

                if (SvROK(retrieve_cxt->eval) && SvTYPE(SvRV(retrieve_cxt->eval)) == SVt_PVCV) {
                        PUSHMARK(sp);
                        XPUSHs(sv_2mortal(newSVsv(sub)));
                        PUTBACK;
                        count = call_sv(retrieve_cxt->eval, G_SCALAR);
                } else {
                        SV *old_errsv = sv_mortalcopy(ERRSV);
                        count = eval_sv(sub, G_SCALAR);
                        if (SvTRUE_NN(ERRSV))
                                Perl_croak(aTHX_ NULL);
                        sv_setsv(ERRSV, old_errsv);
                }
                if (count != 1)
                        CROAK(("Unexpected return value from $Storable::Eval callback\n"));

                SPAGAIN;
                cv = POPs;
                PUTBACK;

                if (!(cv && SvROK(cv) && SvTYPE(SvRV(cv)) == SVt_PVCV))
                        CROAK(("code %s did not evaluate to a subroutine reference\n", SvPV_nolen(sub)));
                
                sub = SvRV(cv);
                av_store(retrieve_cxt->aseen, tagnum, SvREFCNT_inc_NN(sub)); /* fix up the dummy entry... */
                FREETMPS;
                LEAVE;
                
        }
        else if (!forgive_me(aTHX))
                CROAK(("Can't eval, please set $Storable::Eval to a true value"));
#endif
        return SvREFCNT_inc_NN(sub);
}

/*
 * old_retrieve_array
 *
 * Retrieve a whole array in pre-0.6 binary format.
 *
 * Layout is SX_ARRAY <size> followed by each item, in increasing index order.
 * Each item is stored as SX_ITEM <object> or SX_IT_UNDEF for "holes".
 *
 * When we come here, SX_ARRAY has been read already.
 */
static SV *old_retrieve_array(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname)
{
	I32 len;
	I32 i;
	AV *av;
	SV *sv;
	int c;

	PERL_UNUSED_ARG(cname);
	TRACEME(("old_retrieve_array (#%d)", retrieve_cxt->tagnum));

	/*
	 * Read length, and allocate array, then pre-extend it.
	 */

	READ_I32(len);
	TRACEME(("size = %d", len));
	av = newAV();
	SEEN_no_inc(av, 0);

	/*
	 * Now get each item in turn...
	 */

	for (i = 0; i < len; i++) {
		READ_UCHAR(c);
		if (c == SX_IT_UNDEF) {
			TRACEME(("(#%d) undef item", i));
			continue;			/* av_extend() already filled us with undef */
		}
		if (c != SX_ITEM)
			(void) retrieve_other(aTHX_ retrieve_cxt, 0);	/* Will croak out */
		TRACEME(("(#%d) item", i));
		sv = retrieve(aTHX_ retrieve_cxt, 0); /* Retrieve item */
                ASSERT(sv, ("retrieve returns not NULL"));
		av_store_safe(aTHX_ av, i, sv);
	}

	TRACEME(("ok (old_retrieve_array at 0x%"UVxf")", PTR2UV(av)));

	return SvREFCNT_inc_NN((SV *)av);
}

/*
 * old_retrieve_hash
 *
 * Retrieve a whole hash table in pre-0.6 binary format.
 *
 * Layout is SX_HASH <size> followed by each key/value pair, in random order.
 * Keys are stored as SX_KEY <length> <data>, the <data> section being omitted
 * if length is 0.
 * Values are stored as SX_VALUE <object> or SX_VL_UNDEF for "holes".
 *
 * When we come here, SX_HASH has been read already.
 */
static SV *old_retrieve_hash(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname)
{
	I32 len;
	I32 size;
	I32 i;
	HV *hv;
	SV *sv = (SV *) 0;
	int c;
	SV *sv_h_undef = (SV *) 0;		/* hv_store() bug */

	PERL_UNUSED_ARG(cname);
	TRACEME(("old_retrieve_hash (#%d)", retrieve_cxt->tagnum));

	/*
	 * Read length, allocate table.
	 */

	READ_I32(len);
	TRACEME(("size = %d", len));
	hv = newHV();
	SEEN_no_inc(hv, 0);
	if (len) {
                hv_ksplit(hv, len + 1);		/* pre-extend hash to save multiple splits */

                /*
                 * Now get each key/value pair in turn...
                 */

                for (i = 0; i < len; i++) {
                        const char *kbuf;
                        /*
                         * Get value first.
                         */

                        READ_UCHAR(c);
                        if (c == SX_VL_UNDEF) {
                                TRACEME(("(#%d) undef value", i));
                                /*
                                 * Due to a bug in hv_store(), it's not possible to pass
                                 * &PL_sv_undef to hv_store() as a value, otherwise the
                                 * associated key will not be creatable any more. -- RAM, 14/01/97
                                 */
                                if (!sv_h_undef)
                                        sv_h_undef = sv_newmortal();
                                sv = sv_h_undef;
                        } else if (c == SX_VALUE) {
                                TRACEME(("(#%d) value", i));
                                sv = retrieve(aTHX_ retrieve_cxt, 0);
                                ASSERT(sv, ("retrieve returns not NULL"));
                                SvREFCNT_dec(sv);
                        } else
                                (void) retrieve_other(aTHX_ retrieve_cxt, 0);	/* Will croak out */

                        /*
                         * Get key.
                         * Since we're reading into kbuf, we must ensure we're not
                         * recursing between the read and the hv_store() where it's used.
                         * Hence the key comes after the value.
                         */

                        READ_UCHAR(c);
                        if (c != SX_KEY)
                                (void) retrieve_other(aTHX_ retrieve_cxt, 0);	/* Will croak out */
                        READ_I32(size);						/* Get key size */
                        READ_KEY(kbuf, size);
                        TRACEME(("(#%d) key '%s'", i, kbuf));

                        /*
                         * Enter key/value pair into hash table.
                         */

                        hv_store_safe(aTHX_ hv, kbuf, (U32) size, SvREFCNT_inc_NN(sv));
                }

                TRACEME(("ok (retrieve_hash at 0x%"UVxf")", PTR2UV(hv)));
        }

	return SvREFCNT_inc_NN((SV *)hv);
}

/***
 *** Retrieval engine.
 ***/

/*
 * magic_check
 *
 * Make sure the stored data we're trying to retrieve has been produced
 * on an ILP compatible system with the same byteorder. It croaks out in
 * case an error is detected. [ILP = integer-long-pointer sizes]
 * Returns null if error is detected, &PL_sv_undef otherwise.
 *
 * Note that there's no byte ordering info emitted when network order was
 * used at store time.
 */

static void
magic_check(pTHX_ retrieve_cxt_t *retrieve_cxt)
{
    /* The worst case for a malicious header would be old magic (which is
       longer), major, minor, byteorder length byte of 255, 255 bytes of
       garbage, sizeof int, long, pointer, NV.
       So the worse of that we can read is 255 bytes of garbage plus 4.
       Err, I am assuming 8 bit bytes here. Please file a bug report if you're
       compiling perl on a system with chars that are larger than 8 bits.
       (Even Crays aren't *that* perverse).
    */
    unsigned char buf[4 + 255];
    unsigned char *current;
    int c;
    int length;
    int use_network_order;
    int use_NV_size;
    int old_magic = 0;
    int version_major;
    int version_minor = 0;

    TRACEME(("magic_check"));

    retrieve_cxt->on_magic_check = 1;

    /*
     * The "magic number" is only for files, not when freezing in memory.
     */

    if (retrieve_cxt->input_fh) {
        /* This includes the '\0' at the end.  I want to read the extra byte,
           which is usually going to be the major version number.  */
        STRLEN len = sizeof(magicstr);
        STRLEN old_len;

        READ_BYTES(buf, (SSize_t)(len));	/* Not null-terminated */

        /* Point at the byte after the byte we read.  */
        current = buf + --len;	/* Do the -- outside of macros.  */

        if (memNE(buf, magicstr, len)) {
            /*
             * Try to read more bytes to check for the old magic number, which
             * was longer.
             */

            TRACEME(("trying for old magic number"));

            old_len = sizeof(old_magicstr) - 1;
            READ_BYTES(current + 1, (SSize_t)(old_len - len));
            
            if (memNE(buf, old_magicstr, old_len))
                CROAK(("File is not a perl storable"));
	    old_magic++;
            current = buf + old_len;
        }
        use_network_order = *current;
    } else {
            READ_UCHAR(use_network_order);
    }
    
        
    /*
     * Starting with 0.6, the "use_network_order" byte flag is also used to
     * indicate the version number of the binary, and therefore governs the
     * setting of sv_retrieve_vtbl. See magic_write().
     */
    if (old_magic && use_network_order > 1) {
	/*  0.1 dump - use_network_order is really byte order length */
	version_major = -1;
    }
    else {
        version_major = use_network_order >> 1;
    }

    TRACEME(("magic_check: netorder = 0x%x", use_network_order));

    /*
     * Starting with 0.7 (binary major 2), a full byte is dedicated to the
     * minor version of the protocol.  See magic_write().
     */

    if (version_major > 1)
            READ_UCHAR(version_minor);

    retrieve_cxt->ver_major = version_major;
    retrieve_cxt->ver_minor = version_minor;

    TRACEME(("binary image version is %d.%d", version_major, version_minor));

    /*
     * Inter-operability sanity check: we can't retrieve something stored
     * using a format more recent than ours, because we have no way to
     * know what has changed, and letting retrieval go would mean a probable
     * failure reporting a "corrupted" storable file.
     */

    if (
        version_major > STORABLE_BIN_MAJOR ||
        (version_major == STORABLE_BIN_MAJOR &&
         version_minor > STORABLE_BIN_MINOR)
        ) {
        int croak_now = 1;
        TRACEME(("but I am version is %d.%d", STORABLE_BIN_MAJOR,
                 STORABLE_BIN_MINOR));

        if (version_major == STORABLE_BIN_MAJOR) {
            TRACEME(("retrieve_cxt->accept_future_minor is %d",
                     retrieve_cxt->accept_future_minor));
            if (retrieve_cxt->accept_future_minor < 0)
                retrieve_cxt->accept_future_minor
                    = (SvTRUE(perl_get_sv("Storable::accept_future_minor",
                                          GV_ADD))
                       ? 1 : 0);
            if (retrieve_cxt->accept_future_minor == 1)
                croak_now = 0;  /* Don't croak yet.  */
        }
        if (croak_now) {
            CROAK(("Storable binary image v%d.%d more recent than I am (v%d.%d)",
                   version_major, version_minor,
                   STORABLE_BIN_MAJOR, STORABLE_BIN_MINOR));
        }
    }

    /*
     * If they stored using network order, there's no byte ordering
     * information to check.
     */

    if (!(retrieve_cxt->netorder = (use_network_order & 0x1))) {
            /* byte ordering info follows */

            use_NV_size = version_major >= 2 && version_minor >= 2;
            
            if (version_major >= 0) {
                    READ_UCHAR(c);
            }
            else {
                    c = use_network_order;
            }
            length = c + 3 + use_NV_size;
            READ_BYTES(buf, length);	/* Not null-terminated */

            TRACEME(("byte order '%.*s' %d", c, buf, c));

#ifdef USE_56_INTERWORK_KLUDGE
            /* No point in caching this in the context as we only need it once per
               retrieve, and we need to recheck it each read.  */
            if (SvTRUE(perl_get_sv("Storable::interwork_56_64bit", GV_ADD))) {
                    if ((c != (sizeof (byteorderstr_56) - 1))
                        || memNE(buf, byteorderstr_56, c))
                            CROAK(("Byte order is not compatible"));
            } else
#endif
            {
                    if ((c != (sizeof (byteorderstr) - 1)) || memNE(buf, byteorderstr, c))
                            CROAK(("Byte order is not compatible"));
            }

            current = buf + c;
    
            /* sizeof(int) */
            if ((int) *current++ != sizeof(int))
                    CROAK(("Integer size is not compatible"));

            /* sizeof(long) */
            if ((int) *current++ != sizeof(long))
                    CROAK(("Long integer size is not compatible"));

            /* sizeof(char *) */
            if ((int) *current != sizeof(char *))
                    CROAK(("Pointer size is not compatible"));

            if (use_NV_size) {
                    /* sizeof(NV) */
                    if ((int) *++current != sizeof(NV))
                            CROAK(("Double size is not compatible"));
            }
    }
    retrieve_cxt->on_magic_check = 0;
}

/*
 * retrieve
 *
 * Recursively retrieve objects from the specified file and return their
 * root SV (which may be an AV or an HV for what we care).
 * Returns null if there is a problem.
 */
static SV *retrieve(pTHX_ retrieve_cxt_t *retrieve_cxt, const char *cname)
{
	int type;
	SV **svh;
	SV *sv;

	TRACEME(("retrieve"));

	/*
	 * Grab address tag which identifies the object if we are retrieving
	 * an older format. Since the new binary format counts objects and no
	 * longer explicitly tags them, we must keep track of the correspondence
	 * ourselves.
	 *
	 * The following section will disappear one day when the old format is
	 * no longer supported, hence the final "goto" in the "if" block.
	 */

	if (retrieve_cxt->hseen) {						/* Retrieving old binary */
		unsigned long tag;
		if (retrieve_cxt->netorder) {
			I32 nettag;
			READ_BYTES(&nettag, sizeof(I32));		/* Ordered sequence of I32 */
			tag = (unsigned long) nettag;
		} else
			READ_BYTES(&tag, sizeof(tag));		/* Original address of the SV */

		READ_UCHAR(type);
		if (type == SX_OBJECT) {
			I32 tagn;
			svh = hv_fetch(retrieve_cxt->hseen, (char *) &tag, sizeof(tag), FALSE);
			if (!svh)
				CROAK(("Old tag 0x%"UVxf" should have been mapped already",
					(UV) tag));
			tagn = SvIV(*svh);	/* Mapped tag number computed earlier below */

			/*
			 * The following code is common with the SX_OBJECT case below.
			 */

			svh = av_fetch(retrieve_cxt->aseen, tagn, FALSE);
			if (!svh)
				CROAK(("Object #0x%"UVxf" should have been retrieved already [2]",
					(UV) tagn));
			sv = *svh;
			TRACEME(("has retrieved #%d at 0x%"UVxf, tagn, PTR2UV(sv)));
			SvREFCNT_inc_NN(sv);	/* One more reference to this same sv */
			return sv;			/* The SV pointer where object was retrieved */
		}

		/*
		 * Map new object, but don't increase tagnum. This will be done
		 * by each of the retrieve_* functions when they call SEEN().
		 *
		 * The mapping associates the "tag" initially present with a unique
		 * tag number. See test for SX_OBJECT above to see how this is perused.
		 */

		hv_store_safe(aTHX_ retrieve_cxt->hseen, (char *) &tag, sizeof(tag),
                              newSViv(retrieve_cxt->tagnum));

		goto first_time;
	}

	/*
	 * Regular post-0.6 binary format.
	 */

	READ_UCHAR(type);

	TRACEME(("retrieve type = %d", type));

	/*
	 * Are we dealing with an object we should have already retrieved?
	 */

	if (type == SX_OBJECT) {
		I32 tag;
		READ_I32N(tag);
		svh = av_fetch(retrieve_cxt->aseen, tag, FALSE);
		if (!svh)
			CROAK(("Object #0x%"UVxf" should have been retrieved already [3]",
				(UV) tag));
		sv = *svh;
		TRACEME(("had retrieved #%d at 0x%"UVxf, tag, PTR2UV(sv)));
		SvREFCNT_inc_NN(sv);	/* One more reference to this same sv */
		return sv;			/* The SV pointer where object was retrieved */
	} else if (type >= SX_ERROR && retrieve_cxt->ver_minor > STORABLE_BIN_MINOR) {
            if (retrieve_cxt->accept_future_minor < 0)
                retrieve_cxt->accept_future_minor
                    = (SvTRUE(perl_get_sv("Storable::accept_future_minor",
                                          GV_ADD))
                       ? 1 : 0);
            if (retrieve_cxt->accept_future_minor == 1) {
                CROAK(("Storable binary image v%d.%d contains data of type %d. "
                       "This Storable is v%d.%d and can only handle data types up to %d",
                       retrieve_cxt->ver_major, retrieve_cxt->ver_minor, type,
                       STORABLE_BIN_MAJOR, STORABLE_BIN_MINOR, SX_ERROR - 1));
            }
        }

first_time:		/* Will disappear when support for old format is dropped */

	/*
	 * Okay, first time through for this one.
	 */

	sv = RETRIEVE(retrieve_cxt, type)(aTHX_ retrieve_cxt, cname);
        ASSERT(sv, ("RETRIEVE returns non NULL"));

	/*
	 * Old binary formats (pre-0.7).
	 *
	 * Final notifications, ended by SX_STORED may now follow.
	 * Currently, the only pertinent notification to apply on the
	 * freshly retrieved object is either:
	 *    SX_CLASS <char-len> <classname> for short classnames.
	 *    SX_LG_CLASS <int-len> <classname> for larger one (rare!).
	 * Class name is then read into the key buffer pool used by
	 * hash table key retrieval.
	 */

	if (retrieve_cxt->ver_major < 2) {
                while (1) {
			I32 len;
			const char *kbuf;
                        READ_UCHAR(type);
			switch (type) {
                        case SX_STORED:
                                goto done;
			case SX_CLASS:
				READ_UCHAR(len);			/* Length coded on a single char */
				break;
			case SX_LG_CLASS:			/* Length coded on a regular integer */
				READ_I32(len);
				break;
			case EOF:
			default:
                                Perl_croak(aTHX_ "unexpected type %d on stream", type);
			}
			READ_KEY(kbuf, len);
			BLESS(sv, kbuf);
		}
	}
done:
	TRACEME(("ok (retrieved 0x%"UVxf", refcnt=%d, %s)", PTR2UV(sv),
		SvREFCNT(sv) - 1, sv_reftype(sv, FALSE)));

	return sv;	/* Ok */
}

static SV *
promote_root_sv_to_rv(pTHX_ SV *sv) {
        SV *rv;

        ASSERT(sv, ("promote_root_sv_to_rv gets a non NULL"));

        TRACEME(("retrieve got %s(0x%"UVxf")",
                 sv_reftype(sv, FALSE), PTR2UV(sv)));

        rv = newRV_noinc(sv);

        /*
         * If reference is overloaded, restore behaviour.
         *
         * NB: minor glitch here: normally, overloaded refs are stored specially
         * so that we can croak when behaviour cannot be re-installed, and also
         * avoid testing for overloading magic at each reference retrieval.
         *
         * Unfortunately, the root reference is implicitly stored, so we must
         * check for possible overloading now.  Furthermore, if we don't restore
         * overloading, we cannot croak as if the original ref was, because we
         * have no way to determine whether it was an overloaded ref or not in
         * the first place.
         *
         * It's a pity that overloading magic is attached to the rv, and not to
         * the underlying sv as blessing is.
         */

        /* FIXME: isn't AMAGIC gone? */
        if (SvOBJECT(sv)) {
                HV *stash = (HV *) SvSTASH(sv);
		
                if (stash && Gv_AMG(stash)) {
                        SvAMAGIC_on(rv);
                        TRACEME(("restored overloading on root reference"));
                }
                TRACEME(("ended do_retrieve() with an object"));
        }
        else {
                TRACEME(("regular do_retrieve() end"));
        }
        return rv;
}

/*
 * do_retrieve
 *
 * Retrieve data held in file and return the root object.
 * Common routine for pretrieve and mretrieve.
 */
static SV *do_retrieve(pTHX_ PerlIO *f, SV *in) {
	retrieve_cxt_t retrieve_cxt;
	SV *sv;
	int pre_06_fmt = 0;			/* True with pre Storable 0.6 formats */

	TRACEME(("do_retrieve"));

	/*
	 * Sanity assertions for retrieve dispatch tables.
	 */

	ASSERT(sizeof(sv_old_retrieve) == sizeof(sv_retrieve),
		("old and new retrieve dispatch table have same size"));
	ASSERT(sv_old_retrieve[SX_ERROR] == retrieve_other,
		("SX_ERROR entry correctly initialized in old dispatch table"));
	ASSERT(sv_retrieve[SX_ERROR] == retrieve_other,
		("SX_ERROR entry correctly initialized in new dispatch table"));
        ASSERT(((f || in) && !(f && in)),
                ("one and only one of f and in must be not null"));

	/*
	 * Now that STORABLE_xxx hooks exist, it is possible that they try to
	 * re-enter retrieve() via the hooks.
	 */

	/*
	 * Prepare context.
	 *
	 * Data is loaded into the memory buffer when f is NULL, unless 'in' is
	 * also NULL, in which case we're expecting the data to already lie
	 * in the buffer (dclone case).
	 */

	init_retrieve_cxt(aTHX_ &retrieve_cxt);

	retrieve_cxt.is_tainted = f ? 1 : SvTAINTED(in);
	TRACEME(("input source is %s", retrieve_cxt.is_tainted ? "tainted" : "trusted"));

	if (!f) {
                STRLEN size;
#ifdef SvUTF8_on
		if (SvMAGICAL(in) || SvUTF8(in))
#else
		if (SvMAGICAL(in))
#endif
		{
			in = sv_mortalcopy(in);
#ifdef SvUTF8_on
			if (!sv_utf8_downgrade(in, 1))
				CROAK(("Frozen string corrupt - contains characters outside 0-255"));
#endif
		}
		retrieve_cxt.input = (const unsigned char *)SvPV(in, size);
                retrieve_cxt.input_end = retrieve_cxt.input + size;
	}

	retrieve_cxt.input_fh = f; /* Where I/O are performed */

	/*
	 * Check whether input source is tainted, so that we don't wrongly
	 * taint perfectly good values...
	 */

	/*
	 * Magic number verifications:
	 */

	magic_check(aTHX_ &retrieve_cxt);

	if (retrieve_cxt.ver_major > 0) {
		retrieve_cxt.retrieve_vtbl = sv_retrieve;
	}
	else {
		retrieve_cxt.retrieve_vtbl = sv_old_retrieve;
		retrieve_cxt.hseen = newHV();
	}

	TRACEME(("data stored in %s format",
		retrieve_cxt.netorder ? "net order" : "native"));

        sv_setpvs(state_sv(aTHX), "retrieving");
	sv = retrieve(aTHX_ &retrieve_cxt, 0);		/* Recursively retrieve object, get root SV */
        ASSERT(sv, ("retrive returns non NULL"));

        sv_setiv(GvSV(gv_fetchpvs("Storable::last_op_in_netorder",  GV_ADDMULTI, SVt_PV)),
                 (retrieve_cxt.netorder > 0 ? 1 : 0));

	if (retrieve_cxt.ver_major == 0) {
		/*
		 * Backward compatibility with Storable-0.5@9 (which we know we
		 * are retrieving if hseen is non-null): don't create an extra RV
		 * for objects since we special-cased it at store time.
		 *
		 * Build a reference to the SV returned by pretrieve even if it is
		 * already one and not a scalar, for consistency reasons.
		 */
		SV *rv;
		TRACEME(("fixing for old formats -- pre 0.6"));
		if (sv_type(aTHX_ sv) == svis_REF && (rv = SvRV(sv)) && SvOBJECT(rv)) {
			TRACEME(("ended do_retrieve() with an object -- pre 0.6"));
			return sv;
		}
	}

	return promote_root_sv_to_rv(aTHX_ sv);
}

/*
 * pretrieve
 *
 * Retrieve data held in file and return the root object, undef on error.
 */
static SV *pretrieve(pTHX_ PerlIO *f)
{
	TRACEME(("pretrieve"));
	return do_retrieve(aTHX_ f, Nullsv);
}

/*
 * mretrieve
 *
 * Retrieve data held in scalar and return the root object, undef on error.
 */
static SV *mretrieve(pTHX_ SV *sv)
{
	TRACEME(("mretrieve"));
	return do_retrieve(aTHX_ (PerlIO*) 0, sv);
}

/***
 *** Deep cloning
 ***/

/*
 * dclone
 *
 * Deep clone: returns a fresh copy of the original referenced SV tree.
 *
 * This is achieved by storing the object in memory and restoring from
 * there. Not that efficient, but it should be faster than doing it from
 * pure perl anyway.
 */
static SV *dclone(pTHX_ SV *in)
{
        store_cxt_t store_cxt;
	retrieve_cxt_t retrieve_cxt;
	STRLEN size;
	SV *sv;
        SV *state;

	TRACEME(("dclone"));

	/*
	 * Tied elements seem to need special handling.
	 */

	if ((SvTYPE(in) == SVt_PVLV
#if ((PERL_VERSION < 8) || ((PERL_VERSION == 8) && (PERL_SUBVERSION < 1)))
	     || SvTYPE(in) == SVt_PVMG
#endif
	     ) && SvRMAGICAL(in) && mg_find(in, 'p')) {
		mg_get(in);
	}

        if (!SvROK(in))
		CROAK(("Not a reference"));
	sv = SvRV(in);			/* So follow it to know what to store */

        init_store_cxt(aTHX_ &store_cxt, NULL, 0);
        store_cxt.cloning = 1;
        state = state_sv(aTHX);
        sv_setpvs(state, "storing");
        store(aTHX_ &store_cxt, sv);

	TRACEME(("dclone stored %d bytes", SvCUR(store_cxt.output_sv)));

	init_retrieve_cxt(aTHX_ &retrieve_cxt);
        retrieve_cxt.cloning = 1;
	retrieve_cxt.ver_major = STORABLE_BIN_MAJOR;
	retrieve_cxt.ver_minor = STORABLE_BIN_MINOR;
       	retrieve_cxt.is_tainted = SvTAINTED(in);
	retrieve_cxt.retrieve_vtbl = sv_retrieve;
	retrieve_cxt.netorder = 0;
        retrieve_cxt.input = (const unsigned char *)SvPV(store_cxt.output_sv, size);
        retrieve_cxt.input_end = retrieve_cxt.input + size;

        sv_setpvs(state, "retrieving");
	sv = retrieve(aTHX_ &retrieve_cxt, 0);
	return promote_root_sv_to_rv(aTHX_ sv);
}

/***
 *** Glue with perl.
 ***/

/*
 * The Perl IO GV object distinguishes between input and output for sockets
 * but not for plain files. To allow Storable to transparently work on
 * plain files and sockets transparently, we have to ask xsubpp to fetch the
 * right object for us. Hence the OutputStream and InputStream declarations.
 *
 * Before perl 5.004_05, those entries in the standard typemap are not
 * defined in perl include files, so we do that here.
 */

#ifndef OutputStream
#define OutputStream	PerlIO *
#define InputStream		PerlIO *
#endif	/* !OutputStream */

MODULE = Storable	PACKAGE = Storable

PROTOTYPES: ENABLE

BOOT:
{
    HV *stash = gv_stashpvn("Storable", 8, GV_ADD);
    newCONSTSUB(stash, "BIN_MAJOR", newSViv(STORABLE_BIN_MAJOR));
    newCONSTSUB(stash, "BIN_MINOR", newSViv(STORABLE_BIN_MINOR));
    newCONSTSUB(stash, "BIN_WRITE_MINOR", newSViv(STORABLE_BIN_WRITE_MINOR));

    gv_fetchpv("Storable::drop_utf8",   GV_ADDMULTI, SVt_PV);
#ifdef DEBUGME
    /* Only disable the used only once warning if we are in debugging mode.  */
    gv_fetchpv("Storable::DEBUGME",   GV_ADDMULTI, SVt_PV);
#endif
#ifdef USE_56_INTERWORK_KLUDGE
    gv_fetchpv("Storable::interwork_56_64bit",   GV_ADDMULTI, SVt_PV);
#endif
}

# pstore
#
# Store the transitive data closure of given object to disk.
# Returns undef on error, a true value otherwise.

# net_pstore
#
# Same as pstore(), but network order is used for integers and doubles are
# emitted as strings.

SV *
pstore(f,obj)
OutputStream	f
SV *	obj
 ALIAS:
   net_pstore = 1
 CODE:
  do_store(aTHX_ f, obj, ix, (SV **)0);
  RETVAL = &PL_sv_yes;
 OUTPUT:
  RETVAL

# mstore
#
# Store the transitive data closure of given object to memory.
# Returns undef on error, a scalar value containing the data otherwise.

# net_mstore
#
# Same as mstore(), but network order is used for integers and doubles are
# emitted as strings.

SV *
mstore(obj)
SV *	obj
 ALIAS:
  net_mstore = 1
 CODE:
  do_store(aTHX_ (PerlIO*) 0, obj, ix, &RETVAL);
 OUTPUT:
  RETVAL

SV *
pretrieve(f)
InputStream	f
 CODE:
  RETVAL = pretrieve(aTHX_ f);
 OUTPUT:
  RETVAL

SV *
mretrieve(sv)
SV *	sv
 CODE:
  RETVAL = mretrieve(aTHX_ sv);
 OUTPUT:
  RETVAL

SV *
dclone(sv)
SV *	sv
 CODE:
  RETVAL = dclone(aTHX_ sv);
 OUTPUT:
  RETVAL
