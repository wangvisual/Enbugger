#define PERL_CORE
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "ppport.h"

/*
 * COPYRIGHT AND LICENCE
 *
 * Copyright (C) 2007,2008 WhitePages.com, Inc. with primary development by
 * Joshua ben Jore.
 *
 * This program is distributed WITHOUT ANY WARRANTY, including but not
 * limited to the implied warranties of merchantability or fitness for
 * a particular purpose.
 *
 * The program is free software.  You may distribute it and/or modify
 * it under the terms of the GNU General Public License as published
 * by the Free Software Foundation (either version 2 or any later
 * version) and the Perl Artistic License as published by O’Reilly
 * Media, Inc.  Please open the files named gpl-2.0.txt and Artistic
 * for a copy of these licenses.
 */


/*
 * Debugging diagnostics.
 */
#define DEBUG (!!EnbuggerDebugMode)
I32 EnbuggerDebugMode = 0;

static void
S_init_dbargs(pTHX)
{
    AV *const args = PL_dbargs = GvAV(gv_AVadd((gv_fetchpvs("DB::args",
                                                            GV_ADDMULTI,
                                                            SVt_PVAV))));

    if (AvREAL(args)) {
        /* Someone has already created it.
           It might have entries, and if we just turn off AvREAL(), they will
           "leak" until global destruction.  */
        av_clear(args);
        if (SvTIED_mg((const SV *)args, PERL_MAGIC_tied))
            Perl_croak(aTHX_ "Cannot set tied @DB::args");
    }
    AvREIFY_only(PL_dbargs);
}

void
Perl_init_debugger(pTHX)
{
    HV * const ostash = PL_curstash;
    MAGIC *mg;

    /* Only initialize if not already done */
    if (PL_DBgv && PL_DBline && PL_DBsub && PL_DBsingle && PL_DBtrace && PL_DBsignal)
        return;

    PL_curstash = (HV *)SvREFCNT_inc_simple(PL_debstash);

    S_init_dbargs(aTHX);

    /* Match original Perl behavior: just set these without decrementing old values.
     * The original Perl assumes init_debugger is called only once at startup.
     * We guard against multiple calls with the check above. */
    PL_DBgv = GvREFCNT_inc(gv_fetchpvs("DB::DB", GV_ADDMULTI, SVt_PVGV));
    PL_DBline = GvREFCNT_inc(gv_fetchpvs("DB::dbline", GV_ADDMULTI, SVt_PVAV));
    PL_DBsub = GvREFCNT_inc(gv_HVadd(gv_fetchpvs("DB::sub", GV_ADDMULTI, SVt_PVHV)));

    PL_DBsingle = GvSV((gv_fetchpvs("DB::single", GV_ADDMULTI, SVt_PV)));
    if (!SvIOK(PL_DBsingle))
        sv_setiv(PL_DBsingle, 0);
    /* Only add magic if not already present */
    if (!SvMAGICAL(PL_DBsingle) || !mg_find(PL_DBsingle, PERL_MAGIC_debugvar)) {
        mg = sv_magicext(PL_DBsingle, NULL, PERL_MAGIC_debugvar, &PL_vtbl_debugvar, 0, 0);
        mg->mg_private = DBVARMG_SINGLE;
        SvSETMAGIC(PL_DBsingle);
    }

    PL_DBtrace = GvSV((gv_fetchpvs("DB::trace", GV_ADDMULTI, SVt_PV)));
    if (!SvIOK(PL_DBtrace))
        sv_setiv(PL_DBtrace, 0);
    if (!SvMAGICAL(PL_DBtrace) || !mg_find(PL_DBtrace, PERL_MAGIC_debugvar)) {
        mg = sv_magicext(PL_DBtrace, NULL, PERL_MAGIC_debugvar, &PL_vtbl_debugvar, 0, 0);
        mg->mg_private = DBVARMG_TRACE;
        SvSETMAGIC(PL_DBtrace);
    }

    PL_DBsignal = GvSV((gv_fetchpvs("DB::signal", GV_ADDMULTI, SVt_PV)));
    if (!SvIOK(PL_DBsignal))
        sv_setiv(PL_DBsignal, 0);
    if (!SvMAGICAL(PL_DBsignal) || !mg_find(PL_DBsignal, PERL_MAGIC_debugvar)) {
        mg = sv_magicext(PL_DBsignal, NULL, PERL_MAGIC_debugvar, &PL_vtbl_debugvar, 0, 0);
        mg->mg_private = DBVARMG_SIGNAL;
        SvSETMAGIC(PL_DBsignal);
    }

    SvREFCNT_dec(PL_curstash);
    PL_curstash = ostash;
}


/*
 * The ENBUGGER_DEBUG environment variable toggles debugging. It is
 * checked once during module loading.
 */
static void
set_debug_from_environment(pTHX)
{
  HV *env_hv;
  SV **svp;

  /* Fetch %ENV. */
  env_hv = get_hv("main::ENV",0);
  if ( ! env_hv ) {
    /* Does this ever happen? */
    Perl_croak(aTHX_ "Couldn't fetch %%ENV hash");
  }

  /* Fetch $ENV{ENBUGGER_DEBUG}. */
  svp = hv_fetch(env_hv,"ENBUGGER_DEBUG",0,0);
  if ( ! ( svp && *svp )) {
    EnbuggerDebugMode = 0;
    return;
  }
  
  EnbuggerDebugMode = SvTRUE( *svp );
}


/*
 * Set a nextstate/dbstate op's op_type and op_ppaddr.
 */
static void
alter_cop( pTHX_ SV *rv, I32 op_type )
{
  SV  *sv;
  COP *cop;


  /*
   * Validate that rv is a B::COP object and it has an IV to vetch.
   */
  if (!( sv_isobject(rv)
	 && sv_isa(rv, "B::COP")
	 && SvOK( sv = SvRV(rv) )
	 && SvIOK(sv) )) {
    if ( DEBUG ) {
      PerlIO_printf(Perl_debug_log, "Enbugger: SvOK(o)=%"UVuf" SvROK(o)=%"UVuf" SvIOK(SvRV(o))=%"UVuf"\n",
          SvOK(sv), SvROK(sv), SvIOK(SvRV(sv)));
    }
    Perl_croak(aTHX_ "Expecting a B::COP object");
  }


  /*
   * Change only the function pointer, NOT the op_type.
   * Changing op_type can confuse Perl's op cleanup code during perl_destruct
   * and cause crashes in Perl_pad_free.
   */
  cop = INT2PTR( COP*, SvIV(sv) );
  /* cop->op_type = op_type; */  /* Don't change op_type - causes cleanup crashes */
  cop->op_ppaddr = PL_ppaddr[op_type];

  return;
}






/*
 * All future compilation will result in code without
 * breakpoints. This is typical for code that belongs to debuggers all
 * of which is ordinarily in the DB package.
 *
 * TODO: save off the old values. If the user ever wanted to change
 * these values outside of this module, we'd never know. We should.
 */
static void
compile_with_nextstate() {
  Perl_ppaddr_t fn_nextstate = PL_ppaddr[OP_NEXTSTATE];
  PL_ppaddr[OP_NEXTSTATE]
    = PL_ppaddr[OP_DBSTATE]
    = fn_nextstate;
}


/*
 * All future compilation will result in code with breakpoints.
 */
static void
compile_with_dbstate() {
  Perl_ppaddr_t fn_dbstate = PL_ppaddr[OP_DBSTATE];
  PL_ppaddr[OP_NEXTSTATE]
    = PL_ppaddr[OP_DBSTATE]
    = fn_dbstate;
}






MODULE = Enbugger PACKAGE = Enbugger PREFIX = Enbugger_

PROTOTYPES: DISABLE







=pod

Enable XS debugging.

=cut

void
Enbugger_debug( state )
        I32 state
    CODE:
        EnbuggerDebugMode = state;




=pod

Hooks or unhooks a given B::COP object.

=cut

void
Enbugger__nextstate_cop( o )
    SV * o
  CODE:
    alter_cop( aTHX_ o, OP_NEXTSTATE );

void
Enbugger__dbstate_cop( o )
    SV * o
  CODE:
    alter_cop( aTHX_ o, OP_DBSTATE );





=pod

From perl, state that future compilation will have or not have breakpoint dbstate ops.

=cut

void
Enbugger__compile_with_nextstate(class)
    SV *class
  CODE:
    compile_with_nextstate();

void
Enbugger__compile_with_dbstate(class)
    SV *class
  CODE:
    compile_with_dbstate();




=pod

A perl-available way to initialize various debugger variables like
PL_DBsub.

=cut

void
Enbugger_init_debugger( SV* class )
  CODE:
    if ( DEBUG ) {
      PerlIO_printf(Perl_debug_log,"Enbugger: Initializing debugger\n");
    }

    init_debugger();
    PL_perldb = PERLDB_ALL;


=pod

Set the internal debugger signal flag directly, bypassing magic.
This is needed because Perl 5.42+ has magic on $DB::signal that
resets the value.

=cut

void
Enbugger_set_dbsignal( SV* class, IV value )
  CODE:
    PL_DBsignal_iv = value;

void
Enbugger_set_dbsingle( SV* class, IV value )
  CODE:
    PL_DBsingle_iv = value;




=pod

Sets RMAGIC on the %_<$filename hashes.
The array reference is required because the dbfile magic's MG_OBJ
must point to the corresponding array for magic_setdbline to work.

=cut

void
Enbugger_set_magic_dbfile(hv_ref, av_ref)
    SV *hv_ref
    SV *av_ref
  INIT:
    HV *hv;
    AV *av;
  CODE:
    assert(SvROK(hv_ref));
    assert(SvROK(av_ref));

    hv = (HV*) SvRV(hv_ref);
    av = (AV*) SvRV(av_ref);
    assert(SVt_PVHV == SvTYPE(hv));
    assert(SVt_PVAV == SvTYPE(av));
    /* Pass the array as mg_obj so magic_setdbline can find it */
    hv_magic(hv, (GV*)av, PERL_MAGIC_dbfile);




=pod

Sets up some things thatE<apos>ll be needed for debugging later on. These
may need to be moved into individual "off" and "on" functions so more
of the runtime is cleaned up after loading this module.

=cut

BOOT:
    set_debug_from_environment(aTHX);

    if ( PL_DBgv ) {
      if ( DEBUG ) {
        PerlIO_printf(Perl_debug_log,"Enbugger: Debugger is already loaded\n" );
      }
    }
    else {
      if ( DEBUG ) {
        PerlIO_printf(Perl_debug_log,"Enbugger: Initializing debugger during Enbugger boot\n");
      }
      
      /*
       * Copied right out ouf perl.c. I have no idea what this is used
       * for. I've got the idea that maybe something depends on this
       * so I'm including it for now or until I find out that I'm just
       * cargo-culting something inappropriate.
       */
      sv_setpvn(PERL_DEBUG_PAD(0), "", 0);  /* For regex debugging. */
      sv_setpvn(PERL_DEBUG_PAD(1), "", 0);  /* ext/re needs these */
      sv_setpvn(PERL_DEBUG_PAD(2), "", 0);  /* even without DEBUGGING */
      

      /*
       * It is *mandatory* to initialize the debugger before changing
       * PL_ppaddr. This is to avoid ever compiling code that uses
       * Perl_pp_dbstate without having the required PL_DBsingle, etc
       * variables
       *
       * This will need to be reinitialized again later when an actual
       * debugger is present.
       */
      init_debugger();
    }

MODULE = Enbugger PACKAGE = Enbugger::NYTProf PREFIX = Enbugger_NYTProf_

PROTOTYPES: DISABLE

void
Enbugger_NYTProf_instrument_op(... )
  INIT:
    SV *sv;
    OP *op;
    void *a;
    void *b;
  CODE:
    if (!( SvOK(ST(0))
           && SvROK(ST(0))
           && SvOK( sv = SvRV(ST(0)) )
           && SvIOK(sv) )) {
      return;
    }

    op = INT2PTR(OP*, SvIV(sv));
    if ( PL_ppaddr[op->op_type] != op->op_ppaddr ) {
      op->op_ppaddr = PL_ppaddr[op->op_type];
    }

MODULE = Enbugger PACKAGE = Enbugger PREFIX = Enbugger_

## Local Variables:
## mode: c
## mode: auto-fill
## End:
