// SPDX-License-Identifier: GPL-3.0-or-later
// GENERATED once from the sources named below (the script is not kept); edit with care.
//
// Stand-in for `smithay::input::keyboard::keysyms`, which the ported
// malbiruk/driftwm src/config (https://github.com/malbiruk/driftwm) imports.
// Upstream's module is `xkbcommon::xkb::keysyms` (crate xkbcommon 0.9.0,
// https://github.com/rust-x-bindings/xkbcommon-rs): the `KEY_<name>` constants
// of libxkbcommon's `xkbcommon-keysyms.h`.
//
// Data: keysym names and values from xkeysym 0.2.1
// (https://github.com/notgull/xkeysym) `src/automatically_generated.rs`
// (MIT OR Apache-2.0 OR Zlib, generated from the X.Org xorgproto 2024.1 keysym
// headers), renamed with libxkbcommon's header rule, plus `hpYdiaeresis` from
// xkbcommon 0.9.0 `src/xkb/keysyms.rs` (MIT; X.Org keysym headers). This file
// was generated once from those two sources, cross-checked against
// xkbcommon-rs 0.1.2 (https://github.com/wysiwys/xkbcommon-rs); see docs/crates/core/PORT.md.
//
// Unlike upstream's module this one also carries the name table that
// libxkbcommon keeps in C (`ks_tables.h`), which `xkb::keysym_from_name` needs.

#![allow(non_upper_case_globals)]

pub const KEY_0: u32 = 0x30;
pub const KEY_1: u32 = 0x31;
pub const KEY_2: u32 = 0x32;
pub const KEY_3: u32 = 0x33;
pub const KEY_3270_AltCursor: u32 = 0xfd10;
pub const KEY_3270_Attn: u32 = 0xfd0e;
pub const KEY_3270_BackTab: u32 = 0xfd05;
pub const KEY_3270_ChangeScreen: u32 = 0xfd19;
pub const KEY_3270_Copy: u32 = 0xfd15;
pub const KEY_3270_CursorBlink: u32 = 0xfd0f;
pub const KEY_3270_CursorSelect: u32 = 0xfd1c;
pub const KEY_3270_DeleteWord: u32 = 0xfd1a;
pub const KEY_3270_Duplicate: u32 = 0xfd01;
pub const KEY_3270_Enter: u32 = 0xfd1e;
pub const KEY_3270_EraseEOF: u32 = 0xfd06;
pub const KEY_3270_EraseInput: u32 = 0xfd07;
pub const KEY_3270_ExSelect: u32 = 0xfd1b;
pub const KEY_3270_FieldMark: u32 = 0xfd02;
pub const KEY_3270_Ident: u32 = 0xfd13;
pub const KEY_3270_Jump: u32 = 0xfd12;
pub const KEY_3270_KeyClick: u32 = 0xfd11;
pub const KEY_3270_Left2: u32 = 0xfd04;
pub const KEY_3270_PA1: u32 = 0xfd0a;
pub const KEY_3270_PA2: u32 = 0xfd0b;
pub const KEY_3270_PA3: u32 = 0xfd0c;
pub const KEY_3270_Play: u32 = 0xfd16;
pub const KEY_3270_PrintScreen: u32 = 0xfd1d;
pub const KEY_3270_Quit: u32 = 0xfd09;
pub const KEY_3270_Record: u32 = 0xfd18;
pub const KEY_3270_Reset: u32 = 0xfd08;
pub const KEY_3270_Right2: u32 = 0xfd03;
pub const KEY_3270_Rule: u32 = 0xfd14;
pub const KEY_3270_Setup: u32 = 0xfd17;
pub const KEY_3270_Test: u32 = 0xfd0d;
pub const KEY_4: u32 = 0x34;
pub const KEY_5: u32 = 0x35;
pub const KEY_6: u32 = 0x36;
pub const KEY_7: u32 = 0x37;
pub const KEY_8: u32 = 0x38;
pub const KEY_9: u32 = 0x39;
pub const KEY_A: u32 = 0x41;
pub const KEY_a: u32 = 0x61;
pub const KEY_Aacute: u32 = 0xc1;
pub const KEY_aacute: u32 = 0xe1;
pub const KEY_Abelowdot: u32 = 0x1001ea0;
pub const KEY_abelowdot: u32 = 0x1001ea1;
pub const KEY_abovedot: u32 = 0x1ff;
pub const KEY_Abreve: u32 = 0x1c3;
pub const KEY_abreve: u32 = 0x1e3;
pub const KEY_Abreveacute: u32 = 0x1001eae;
pub const KEY_abreveacute: u32 = 0x1001eaf;
pub const KEY_Abrevebelowdot: u32 = 0x1001eb6;
pub const KEY_abrevebelowdot: u32 = 0x1001eb7;
pub const KEY_Abrevegrave: u32 = 0x1001eb0;
pub const KEY_abrevegrave: u32 = 0x1001eb1;
pub const KEY_Abrevehook: u32 = 0x1001eb2;
pub const KEY_abrevehook: u32 = 0x1001eb3;
pub const KEY_Abrevetilde: u32 = 0x1001eb4;
pub const KEY_abrevetilde: u32 = 0x1001eb5;
pub const KEY_AccessX_Enable: u32 = 0xfe70;
pub const KEY_AccessX_Feedback_Enable: u32 = 0xfe71;
pub const KEY_Acircumflex: u32 = 0xc2;
pub const KEY_acircumflex: u32 = 0xe2;
pub const KEY_Acircumflexacute: u32 = 0x1001ea4;
pub const KEY_acircumflexacute: u32 = 0x1001ea5;
pub const KEY_Acircumflexbelowdot: u32 = 0x1001eac;
pub const KEY_acircumflexbelowdot: u32 = 0x1001ead;
pub const KEY_Acircumflexgrave: u32 = 0x1001ea6;
pub const KEY_acircumflexgrave: u32 = 0x1001ea7;
pub const KEY_Acircumflexhook: u32 = 0x1001ea8;
pub const KEY_acircumflexhook: u32 = 0x1001ea9;
pub const KEY_Acircumflextilde: u32 = 0x1001eaa;
pub const KEY_acircumflextilde: u32 = 0x1001eab;
pub const KEY_acute: u32 = 0xb4;
pub const KEY_Adiaeresis: u32 = 0xc4;
pub const KEY_adiaeresis: u32 = 0xe4;
pub const KEY_AE: u32 = 0xc6;
pub const KEY_ae: u32 = 0xe6;
pub const KEY_Agrave: u32 = 0xc0;
pub const KEY_agrave: u32 = 0xe0;
pub const KEY_Ahook: u32 = 0x1001ea2;
pub const KEY_ahook: u32 = 0x1001ea3;
pub const KEY_Alt_L: u32 = 0xffe9;
pub const KEY_Alt_R: u32 = 0xffea;
pub const KEY_Amacron: u32 = 0x3c0;
pub const KEY_amacron: u32 = 0x3e0;
pub const KEY_ampersand: u32 = 0x26;
pub const KEY_Aogonek: u32 = 0x1a1;
pub const KEY_aogonek: u32 = 0x1b1;
pub const KEY_apostrophe: u32 = 0x27;
pub const KEY_approxeq: u32 = 0x1002248;
pub const KEY_approximate: u32 = 0x8c8;
pub const KEY_Arabic_0: u32 = 0x1000660;
pub const KEY_Arabic_1: u32 = 0x1000661;
pub const KEY_Arabic_2: u32 = 0x1000662;
pub const KEY_Arabic_3: u32 = 0x1000663;
pub const KEY_Arabic_4: u32 = 0x1000664;
pub const KEY_Arabic_5: u32 = 0x1000665;
pub const KEY_Arabic_6: u32 = 0x1000666;
pub const KEY_Arabic_7: u32 = 0x1000667;
pub const KEY_Arabic_8: u32 = 0x1000668;
pub const KEY_Arabic_9: u32 = 0x1000669;
pub const KEY_Arabic_ain: u32 = 0x5d9;
pub const KEY_Arabic_alef: u32 = 0x5c7;
pub const KEY_Arabic_alefmaksura: u32 = 0x5e9;
pub const KEY_Arabic_beh: u32 = 0x5c8;
pub const KEY_Arabic_comma: u32 = 0x5ac;
pub const KEY_Arabic_dad: u32 = 0x5d6;
pub const KEY_Arabic_dal: u32 = 0x5cf;
pub const KEY_Arabic_damma: u32 = 0x5ef;
pub const KEY_Arabic_dammatan: u32 = 0x5ec;
pub const KEY_Arabic_ddal: u32 = 0x1000688;
pub const KEY_Arabic_farsi_yeh: u32 = 0x10006cc;
pub const KEY_Arabic_fatha: u32 = 0x5ee;
pub const KEY_Arabic_fathatan: u32 = 0x5eb;
pub const KEY_Arabic_feh: u32 = 0x5e1;
pub const KEY_Arabic_fullstop: u32 = 0x10006d4;
pub const KEY_Arabic_gaf: u32 = 0x10006af;
pub const KEY_Arabic_ghain: u32 = 0x5da;
pub const KEY_Arabic_ha: u32 = 0x5e7;
pub const KEY_Arabic_hah: u32 = 0x5cd;
pub const KEY_Arabic_hamza: u32 = 0x5c1;
pub const KEY_Arabic_hamza_above: u32 = 0x1000654;
pub const KEY_Arabic_hamza_below: u32 = 0x1000655;
pub const KEY_Arabic_hamzaonalef: u32 = 0x5c3;
pub const KEY_Arabic_hamzaonwaw: u32 = 0x5c4;
pub const KEY_Arabic_hamzaonyeh: u32 = 0x5c6;
pub const KEY_Arabic_hamzaunderalef: u32 = 0x5c5;
pub const KEY_Arabic_heh: u32 = 0x5e7;
pub const KEY_Arabic_heh_doachashmee: u32 = 0x10006be;
pub const KEY_Arabic_heh_goal: u32 = 0x10006c1;
pub const KEY_Arabic_jeem: u32 = 0x5cc;
pub const KEY_Arabic_jeh: u32 = 0x1000698;
pub const KEY_Arabic_kaf: u32 = 0x5e3;
pub const KEY_Arabic_kasra: u32 = 0x5f0;
pub const KEY_Arabic_kasratan: u32 = 0x5ed;
pub const KEY_Arabic_keheh: u32 = 0x10006a9;
pub const KEY_Arabic_khah: u32 = 0x5ce;
pub const KEY_Arabic_lam: u32 = 0x5e4;
pub const KEY_Arabic_madda_above: u32 = 0x1000653;
pub const KEY_Arabic_maddaonalef: u32 = 0x5c2;
pub const KEY_Arabic_meem: u32 = 0x5e5;
pub const KEY_Arabic_noon: u32 = 0x5e6;
pub const KEY_Arabic_noon_ghunna: u32 = 0x10006ba;
pub const KEY_Arabic_peh: u32 = 0x100067e;
pub const KEY_Arabic_percent: u32 = 0x100066a;
pub const KEY_Arabic_qaf: u32 = 0x5e2;
pub const KEY_Arabic_question_mark: u32 = 0x5bf;
pub const KEY_Arabic_ra: u32 = 0x5d1;
pub const KEY_Arabic_rreh: u32 = 0x1000691;
pub const KEY_Arabic_sad: u32 = 0x5d5;
pub const KEY_Arabic_seen: u32 = 0x5d3;
pub const KEY_Arabic_semicolon: u32 = 0x5bb;
pub const KEY_Arabic_shadda: u32 = 0x5f1;
pub const KEY_Arabic_sheen: u32 = 0x5d4;
pub const KEY_Arabic_sukun: u32 = 0x5f2;
pub const KEY_Arabic_superscript_alef: u32 = 0x1000670;
pub const KEY_Arabic_switch: u32 = 0xff7e;
pub const KEY_Arabic_tah: u32 = 0x5d7;
pub const KEY_Arabic_tatweel: u32 = 0x5e0;
pub const KEY_Arabic_tcheh: u32 = 0x1000686;
pub const KEY_Arabic_teh: u32 = 0x5ca;
pub const KEY_Arabic_tehmarbuta: u32 = 0x5c9;
pub const KEY_Arabic_thal: u32 = 0x5d0;
pub const KEY_Arabic_theh: u32 = 0x5cb;
pub const KEY_Arabic_tteh: u32 = 0x1000679;
pub const KEY_Arabic_veh: u32 = 0x10006a4;
pub const KEY_Arabic_waw: u32 = 0x5e8;
pub const KEY_Arabic_yeh: u32 = 0x5ea;
pub const KEY_Arabic_yeh_baree: u32 = 0x10006d2;
pub const KEY_Arabic_zah: u32 = 0x5d8;
pub const KEY_Arabic_zain: u32 = 0x5d2;
pub const KEY_Aring: u32 = 0xc5;
pub const KEY_aring: u32 = 0xe5;
pub const KEY_Armenian_accent: u32 = 0x100055b;
pub const KEY_Armenian_amanak: u32 = 0x100055c;
pub const KEY_Armenian_apostrophe: u32 = 0x100055a;
pub const KEY_Armenian_AT: u32 = 0x1000538;
pub const KEY_Armenian_at: u32 = 0x1000568;
pub const KEY_Armenian_AYB: u32 = 0x1000531;
pub const KEY_Armenian_ayb: u32 = 0x1000561;
pub const KEY_Armenian_BEN: u32 = 0x1000532;
pub const KEY_Armenian_ben: u32 = 0x1000562;
pub const KEY_Armenian_but: u32 = 0x100055d;
pub const KEY_Armenian_CHA: u32 = 0x1000549;
pub const KEY_Armenian_cha: u32 = 0x1000579;
pub const KEY_Armenian_DA: u32 = 0x1000534;
pub const KEY_Armenian_da: u32 = 0x1000564;
pub const KEY_Armenian_DZA: u32 = 0x1000541;
pub const KEY_Armenian_dza: u32 = 0x1000571;
pub const KEY_Armenian_E: u32 = 0x1000537;
pub const KEY_Armenian_e: u32 = 0x1000567;
pub const KEY_Armenian_exclam: u32 = 0x100055c;
pub const KEY_Armenian_FE: u32 = 0x1000556;
pub const KEY_Armenian_fe: u32 = 0x1000586;
pub const KEY_Armenian_full_stop: u32 = 0x1000589;
pub const KEY_Armenian_GHAT: u32 = 0x1000542;
pub const KEY_Armenian_ghat: u32 = 0x1000572;
pub const KEY_Armenian_GIM: u32 = 0x1000533;
pub const KEY_Armenian_gim: u32 = 0x1000563;
pub const KEY_Armenian_HI: u32 = 0x1000545;
pub const KEY_Armenian_hi: u32 = 0x1000575;
pub const KEY_Armenian_HO: u32 = 0x1000540;
pub const KEY_Armenian_ho: u32 = 0x1000570;
pub const KEY_Armenian_hyphen: u32 = 0x100058a;
pub const KEY_Armenian_INI: u32 = 0x100053b;
pub const KEY_Armenian_ini: u32 = 0x100056b;
pub const KEY_Armenian_JE: u32 = 0x100054b;
pub const KEY_Armenian_je: u32 = 0x100057b;
pub const KEY_Armenian_KE: u32 = 0x1000554;
pub const KEY_Armenian_ke: u32 = 0x1000584;
pub const KEY_Armenian_KEN: u32 = 0x100053f;
pub const KEY_Armenian_ken: u32 = 0x100056f;
pub const KEY_Armenian_KHE: u32 = 0x100053d;
pub const KEY_Armenian_khe: u32 = 0x100056d;
pub const KEY_Armenian_ligature_ew: u32 = 0x1000587;
pub const KEY_Armenian_LYUN: u32 = 0x100053c;
pub const KEY_Armenian_lyun: u32 = 0x100056c;
pub const KEY_Armenian_MEN: u32 = 0x1000544;
pub const KEY_Armenian_men: u32 = 0x1000574;
pub const KEY_Armenian_NU: u32 = 0x1000546;
pub const KEY_Armenian_nu: u32 = 0x1000576;
pub const KEY_Armenian_O: u32 = 0x1000555;
pub const KEY_Armenian_o: u32 = 0x1000585;
pub const KEY_Armenian_paruyk: u32 = 0x100055e;
pub const KEY_Armenian_PE: u32 = 0x100054a;
pub const KEY_Armenian_pe: u32 = 0x100057a;
pub const KEY_Armenian_PYUR: u32 = 0x1000553;
pub const KEY_Armenian_pyur: u32 = 0x1000583;
pub const KEY_Armenian_question: u32 = 0x100055e;
pub const KEY_Armenian_RA: u32 = 0x100054c;
pub const KEY_Armenian_ra: u32 = 0x100057c;
pub const KEY_Armenian_RE: u32 = 0x1000550;
pub const KEY_Armenian_re: u32 = 0x1000580;
pub const KEY_Armenian_SE: u32 = 0x100054d;
pub const KEY_Armenian_se: u32 = 0x100057d;
pub const KEY_Armenian_separation_mark: u32 = 0x100055d;
pub const KEY_Armenian_SHA: u32 = 0x1000547;
pub const KEY_Armenian_sha: u32 = 0x1000577;
pub const KEY_Armenian_shesht: u32 = 0x100055b;
pub const KEY_Armenian_TCHE: u32 = 0x1000543;
pub const KEY_Armenian_tche: u32 = 0x1000573;
pub const KEY_Armenian_TO: u32 = 0x1000539;
pub const KEY_Armenian_to: u32 = 0x1000569;
pub const KEY_Armenian_TSA: u32 = 0x100053e;
pub const KEY_Armenian_tsa: u32 = 0x100056e;
pub const KEY_Armenian_TSO: u32 = 0x1000551;
pub const KEY_Armenian_tso: u32 = 0x1000581;
pub const KEY_Armenian_TYUN: u32 = 0x100054f;
pub const KEY_Armenian_tyun: u32 = 0x100057f;
pub const KEY_Armenian_verjaket: u32 = 0x1000589;
pub const KEY_Armenian_VEV: u32 = 0x100054e;
pub const KEY_Armenian_vev: u32 = 0x100057e;
pub const KEY_Armenian_VO: u32 = 0x1000548;
pub const KEY_Armenian_vo: u32 = 0x1000578;
pub const KEY_Armenian_VYUN: u32 = 0x1000552;
pub const KEY_Armenian_vyun: u32 = 0x1000582;
pub const KEY_Armenian_YECH: u32 = 0x1000535;
pub const KEY_Armenian_yech: u32 = 0x1000565;
pub const KEY_Armenian_yentamna: u32 = 0x100058a;
pub const KEY_Armenian_ZA: u32 = 0x1000536;
pub const KEY_Armenian_za: u32 = 0x1000566;
pub const KEY_Armenian_ZHE: u32 = 0x100053a;
pub const KEY_Armenian_zhe: u32 = 0x100056a;
pub const KEY_asciicircum: u32 = 0x5e;
pub const KEY_asciitilde: u32 = 0x7e;
pub const KEY_asterisk: u32 = 0x2a;
pub const KEY_at: u32 = 0x40;
pub const KEY_Atilde: u32 = 0xc3;
pub const KEY_atilde: u32 = 0xe3;
pub const KEY_AudibleBell_Enable: u32 = 0xfe7a;
pub const KEY_B: u32 = 0x42;
pub const KEY_b: u32 = 0x62;
pub const KEY_Babovedot: u32 = 0x1001e02;
pub const KEY_babovedot: u32 = 0x1001e03;
pub const KEY_backslash: u32 = 0x5c;
pub const KEY_BackSpace: u32 = 0xff08;
pub const KEY_BackTab: u32 = 0x1000ff74;
pub const KEY_ballotcross: u32 = 0xaf4;
pub const KEY_bar: u32 = 0x7c;
pub const KEY_because: u32 = 0x1002235;
pub const KEY_Begin: u32 = 0xff58;
pub const KEY_blank: u32 = 0x9df;
pub const KEY_block: u32 = 0x100000fc;
pub const KEY_botintegral: u32 = 0x8a5;
pub const KEY_botleftparens: u32 = 0x8ac;
pub const KEY_botleftsqbracket: u32 = 0x8a8;
pub const KEY_botleftsummation: u32 = 0x8b2;
pub const KEY_botrightparens: u32 = 0x8ae;
pub const KEY_botrightsqbracket: u32 = 0x8aa;
pub const KEY_botrightsummation: u32 = 0x8b6;
pub const KEY_bott: u32 = 0x9f6;
pub const KEY_botvertsummationconnector: u32 = 0x8b4;
pub const KEY_BounceKeys_Enable: u32 = 0xfe74;
pub const KEY_braceleft: u32 = 0x7b;
pub const KEY_braceright: u32 = 0x7d;
pub const KEY_bracketleft: u32 = 0x5b;
pub const KEY_bracketright: u32 = 0x5d;
pub const KEY_braille_blank: u32 = 0x1002800;
pub const KEY_braille_dot_1: u32 = 0xfff1;
pub const KEY_braille_dot_10: u32 = 0xfffa;
pub const KEY_braille_dot_2: u32 = 0xfff2;
pub const KEY_braille_dot_3: u32 = 0xfff3;
pub const KEY_braille_dot_4: u32 = 0xfff4;
pub const KEY_braille_dot_5: u32 = 0xfff5;
pub const KEY_braille_dot_6: u32 = 0xfff6;
pub const KEY_braille_dot_7: u32 = 0xfff7;
pub const KEY_braille_dot_8: u32 = 0xfff8;
pub const KEY_braille_dot_9: u32 = 0xfff9;
pub const KEY_braille_dots_1: u32 = 0x1002801;
pub const KEY_braille_dots_12: u32 = 0x1002803;
pub const KEY_braille_dots_123: u32 = 0x1002807;
pub const KEY_braille_dots_1234: u32 = 0x100280f;
pub const KEY_braille_dots_12345: u32 = 0x100281f;
pub const KEY_braille_dots_123456: u32 = 0x100283f;
pub const KEY_braille_dots_1234567: u32 = 0x100287f;
pub const KEY_braille_dots_12345678: u32 = 0x10028ff;
pub const KEY_braille_dots_1234568: u32 = 0x10028bf;
pub const KEY_braille_dots_123457: u32 = 0x100285f;
pub const KEY_braille_dots_1234578: u32 = 0x10028df;
pub const KEY_braille_dots_123458: u32 = 0x100289f;
pub const KEY_braille_dots_12346: u32 = 0x100282f;
pub const KEY_braille_dots_123467: u32 = 0x100286f;
pub const KEY_braille_dots_1234678: u32 = 0x10028ef;
pub const KEY_braille_dots_123468: u32 = 0x10028af;
pub const KEY_braille_dots_12347: u32 = 0x100284f;
pub const KEY_braille_dots_123478: u32 = 0x10028cf;
pub const KEY_braille_dots_12348: u32 = 0x100288f;
pub const KEY_braille_dots_1235: u32 = 0x1002817;
pub const KEY_braille_dots_12356: u32 = 0x1002837;
pub const KEY_braille_dots_123567: u32 = 0x1002877;
pub const KEY_braille_dots_1235678: u32 = 0x10028f7;
pub const KEY_braille_dots_123568: u32 = 0x10028b7;
pub const KEY_braille_dots_12357: u32 = 0x1002857;
pub const KEY_braille_dots_123578: u32 = 0x10028d7;
pub const KEY_braille_dots_12358: u32 = 0x1002897;
pub const KEY_braille_dots_1236: u32 = 0x1002827;
pub const KEY_braille_dots_12367: u32 = 0x1002867;
pub const KEY_braille_dots_123678: u32 = 0x10028e7;
pub const KEY_braille_dots_12368: u32 = 0x10028a7;
pub const KEY_braille_dots_1237: u32 = 0x1002847;
pub const KEY_braille_dots_12378: u32 = 0x10028c7;
pub const KEY_braille_dots_1238: u32 = 0x1002887;
pub const KEY_braille_dots_124: u32 = 0x100280b;
pub const KEY_braille_dots_1245: u32 = 0x100281b;
pub const KEY_braille_dots_12456: u32 = 0x100283b;
pub const KEY_braille_dots_124567: u32 = 0x100287b;
pub const KEY_braille_dots_1245678: u32 = 0x10028fb;
pub const KEY_braille_dots_124568: u32 = 0x10028bb;
pub const KEY_braille_dots_12457: u32 = 0x100285b;
pub const KEY_braille_dots_124578: u32 = 0x10028db;
pub const KEY_braille_dots_12458: u32 = 0x100289b;
pub const KEY_braille_dots_1246: u32 = 0x100282b;
pub const KEY_braille_dots_12467: u32 = 0x100286b;
pub const KEY_braille_dots_124678: u32 = 0x10028eb;
pub const KEY_braille_dots_12468: u32 = 0x10028ab;
pub const KEY_braille_dots_1247: u32 = 0x100284b;
pub const KEY_braille_dots_12478: u32 = 0x10028cb;
pub const KEY_braille_dots_1248: u32 = 0x100288b;
pub const KEY_braille_dots_125: u32 = 0x1002813;
pub const KEY_braille_dots_1256: u32 = 0x1002833;
pub const KEY_braille_dots_12567: u32 = 0x1002873;
pub const KEY_braille_dots_125678: u32 = 0x10028f3;
pub const KEY_braille_dots_12568: u32 = 0x10028b3;
pub const KEY_braille_dots_1257: u32 = 0x1002853;
pub const KEY_braille_dots_12578: u32 = 0x10028d3;
pub const KEY_braille_dots_1258: u32 = 0x1002893;
pub const KEY_braille_dots_126: u32 = 0x1002823;
pub const KEY_braille_dots_1267: u32 = 0x1002863;
pub const KEY_braille_dots_12678: u32 = 0x10028e3;
pub const KEY_braille_dots_1268: u32 = 0x10028a3;
pub const KEY_braille_dots_127: u32 = 0x1002843;
pub const KEY_braille_dots_1278: u32 = 0x10028c3;
pub const KEY_braille_dots_128: u32 = 0x1002883;
pub const KEY_braille_dots_13: u32 = 0x1002805;
pub const KEY_braille_dots_134: u32 = 0x100280d;
pub const KEY_braille_dots_1345: u32 = 0x100281d;
pub const KEY_braille_dots_13456: u32 = 0x100283d;
pub const KEY_braille_dots_134567: u32 = 0x100287d;
pub const KEY_braille_dots_1345678: u32 = 0x10028fd;
pub const KEY_braille_dots_134568: u32 = 0x10028bd;
pub const KEY_braille_dots_13457: u32 = 0x100285d;
pub const KEY_braille_dots_134578: u32 = 0x10028dd;
pub const KEY_braille_dots_13458: u32 = 0x100289d;
pub const KEY_braille_dots_1346: u32 = 0x100282d;
pub const KEY_braille_dots_13467: u32 = 0x100286d;
pub const KEY_braille_dots_134678: u32 = 0x10028ed;
pub const KEY_braille_dots_13468: u32 = 0x10028ad;
pub const KEY_braille_dots_1347: u32 = 0x100284d;
pub const KEY_braille_dots_13478: u32 = 0x10028cd;
pub const KEY_braille_dots_1348: u32 = 0x100288d;
pub const KEY_braille_dots_135: u32 = 0x1002815;
pub const KEY_braille_dots_1356: u32 = 0x1002835;
pub const KEY_braille_dots_13567: u32 = 0x1002875;
pub const KEY_braille_dots_135678: u32 = 0x10028f5;
pub const KEY_braille_dots_13568: u32 = 0x10028b5;
pub const KEY_braille_dots_1357: u32 = 0x1002855;
pub const KEY_braille_dots_13578: u32 = 0x10028d5;
pub const KEY_braille_dots_1358: u32 = 0x1002895;
pub const KEY_braille_dots_136: u32 = 0x1002825;
pub const KEY_braille_dots_1367: u32 = 0x1002865;
pub const KEY_braille_dots_13678: u32 = 0x10028e5;
pub const KEY_braille_dots_1368: u32 = 0x10028a5;
pub const KEY_braille_dots_137: u32 = 0x1002845;
pub const KEY_braille_dots_1378: u32 = 0x10028c5;
pub const KEY_braille_dots_138: u32 = 0x1002885;
pub const KEY_braille_dots_14: u32 = 0x1002809;
pub const KEY_braille_dots_145: u32 = 0x1002819;
pub const KEY_braille_dots_1456: u32 = 0x1002839;
pub const KEY_braille_dots_14567: u32 = 0x1002879;
pub const KEY_braille_dots_145678: u32 = 0x10028f9;
pub const KEY_braille_dots_14568: u32 = 0x10028b9;
pub const KEY_braille_dots_1457: u32 = 0x1002859;
pub const KEY_braille_dots_14578: u32 = 0x10028d9;
pub const KEY_braille_dots_1458: u32 = 0x1002899;
pub const KEY_braille_dots_146: u32 = 0x1002829;
pub const KEY_braille_dots_1467: u32 = 0x1002869;
pub const KEY_braille_dots_14678: u32 = 0x10028e9;
pub const KEY_braille_dots_1468: u32 = 0x10028a9;
pub const KEY_braille_dots_147: u32 = 0x1002849;
pub const KEY_braille_dots_1478: u32 = 0x10028c9;
pub const KEY_braille_dots_148: u32 = 0x1002889;
pub const KEY_braille_dots_15: u32 = 0x1002811;
pub const KEY_braille_dots_156: u32 = 0x1002831;
pub const KEY_braille_dots_1567: u32 = 0x1002871;
pub const KEY_braille_dots_15678: u32 = 0x10028f1;
pub const KEY_braille_dots_1568: u32 = 0x10028b1;
pub const KEY_braille_dots_157: u32 = 0x1002851;
pub const KEY_braille_dots_1578: u32 = 0x10028d1;
pub const KEY_braille_dots_158: u32 = 0x1002891;
pub const KEY_braille_dots_16: u32 = 0x1002821;
pub const KEY_braille_dots_167: u32 = 0x1002861;
pub const KEY_braille_dots_1678: u32 = 0x10028e1;
pub const KEY_braille_dots_168: u32 = 0x10028a1;
pub const KEY_braille_dots_17: u32 = 0x1002841;
pub const KEY_braille_dots_178: u32 = 0x10028c1;
pub const KEY_braille_dots_18: u32 = 0x1002881;
pub const KEY_braille_dots_2: u32 = 0x1002802;
pub const KEY_braille_dots_23: u32 = 0x1002806;
pub const KEY_braille_dots_234: u32 = 0x100280e;
pub const KEY_braille_dots_2345: u32 = 0x100281e;
pub const KEY_braille_dots_23456: u32 = 0x100283e;
pub const KEY_braille_dots_234567: u32 = 0x100287e;
pub const KEY_braille_dots_2345678: u32 = 0x10028fe;
pub const KEY_braille_dots_234568: u32 = 0x10028be;
pub const KEY_braille_dots_23457: u32 = 0x100285e;
pub const KEY_braille_dots_234578: u32 = 0x10028de;
pub const KEY_braille_dots_23458: u32 = 0x100289e;
pub const KEY_braille_dots_2346: u32 = 0x100282e;
pub const KEY_braille_dots_23467: u32 = 0x100286e;
pub const KEY_braille_dots_234678: u32 = 0x10028ee;
pub const KEY_braille_dots_23468: u32 = 0x10028ae;
pub const KEY_braille_dots_2347: u32 = 0x100284e;
pub const KEY_braille_dots_23478: u32 = 0x10028ce;
pub const KEY_braille_dots_2348: u32 = 0x100288e;
pub const KEY_braille_dots_235: u32 = 0x1002816;
pub const KEY_braille_dots_2356: u32 = 0x1002836;
pub const KEY_braille_dots_23567: u32 = 0x1002876;
pub const KEY_braille_dots_235678: u32 = 0x10028f6;
pub const KEY_braille_dots_23568: u32 = 0x10028b6;
pub const KEY_braille_dots_2357: u32 = 0x1002856;
pub const KEY_braille_dots_23578: u32 = 0x10028d6;
pub const KEY_braille_dots_2358: u32 = 0x1002896;
pub const KEY_braille_dots_236: u32 = 0x1002826;
pub const KEY_braille_dots_2367: u32 = 0x1002866;
pub const KEY_braille_dots_23678: u32 = 0x10028e6;
pub const KEY_braille_dots_2368: u32 = 0x10028a6;
pub const KEY_braille_dots_237: u32 = 0x1002846;
pub const KEY_braille_dots_2378: u32 = 0x10028c6;
pub const KEY_braille_dots_238: u32 = 0x1002886;
pub const KEY_braille_dots_24: u32 = 0x100280a;
pub const KEY_braille_dots_245: u32 = 0x100281a;
pub const KEY_braille_dots_2456: u32 = 0x100283a;
pub const KEY_braille_dots_24567: u32 = 0x100287a;
pub const KEY_braille_dots_245678: u32 = 0x10028fa;
pub const KEY_braille_dots_24568: u32 = 0x10028ba;
pub const KEY_braille_dots_2457: u32 = 0x100285a;
pub const KEY_braille_dots_24578: u32 = 0x10028da;
pub const KEY_braille_dots_2458: u32 = 0x100289a;
pub const KEY_braille_dots_246: u32 = 0x100282a;
pub const KEY_braille_dots_2467: u32 = 0x100286a;
pub const KEY_braille_dots_24678: u32 = 0x10028ea;
pub const KEY_braille_dots_2468: u32 = 0x10028aa;
pub const KEY_braille_dots_247: u32 = 0x100284a;
pub const KEY_braille_dots_2478: u32 = 0x10028ca;
pub const KEY_braille_dots_248: u32 = 0x100288a;
pub const KEY_braille_dots_25: u32 = 0x1002812;
pub const KEY_braille_dots_256: u32 = 0x1002832;
pub const KEY_braille_dots_2567: u32 = 0x1002872;
pub const KEY_braille_dots_25678: u32 = 0x10028f2;
pub const KEY_braille_dots_2568: u32 = 0x10028b2;
pub const KEY_braille_dots_257: u32 = 0x1002852;
pub const KEY_braille_dots_2578: u32 = 0x10028d2;
pub const KEY_braille_dots_258: u32 = 0x1002892;
pub const KEY_braille_dots_26: u32 = 0x1002822;
pub const KEY_braille_dots_267: u32 = 0x1002862;
pub const KEY_braille_dots_2678: u32 = 0x10028e2;
pub const KEY_braille_dots_268: u32 = 0x10028a2;
pub const KEY_braille_dots_27: u32 = 0x1002842;
pub const KEY_braille_dots_278: u32 = 0x10028c2;
pub const KEY_braille_dots_28: u32 = 0x1002882;
pub const KEY_braille_dots_3: u32 = 0x1002804;
pub const KEY_braille_dots_34: u32 = 0x100280c;
pub const KEY_braille_dots_345: u32 = 0x100281c;
pub const KEY_braille_dots_3456: u32 = 0x100283c;
pub const KEY_braille_dots_34567: u32 = 0x100287c;
pub const KEY_braille_dots_345678: u32 = 0x10028fc;
pub const KEY_braille_dots_34568: u32 = 0x10028bc;
pub const KEY_braille_dots_3457: u32 = 0x100285c;
pub const KEY_braille_dots_34578: u32 = 0x10028dc;
pub const KEY_braille_dots_3458: u32 = 0x100289c;
pub const KEY_braille_dots_346: u32 = 0x100282c;
pub const KEY_braille_dots_3467: u32 = 0x100286c;
pub const KEY_braille_dots_34678: u32 = 0x10028ec;
pub const KEY_braille_dots_3468: u32 = 0x10028ac;
pub const KEY_braille_dots_347: u32 = 0x100284c;
pub const KEY_braille_dots_3478: u32 = 0x10028cc;
pub const KEY_braille_dots_348: u32 = 0x100288c;
pub const KEY_braille_dots_35: u32 = 0x1002814;
pub const KEY_braille_dots_356: u32 = 0x1002834;
pub const KEY_braille_dots_3567: u32 = 0x1002874;
pub const KEY_braille_dots_35678: u32 = 0x10028f4;
pub const KEY_braille_dots_3568: u32 = 0x10028b4;
pub const KEY_braille_dots_357: u32 = 0x1002854;
pub const KEY_braille_dots_3578: u32 = 0x10028d4;
pub const KEY_braille_dots_358: u32 = 0x1002894;
pub const KEY_braille_dots_36: u32 = 0x1002824;
pub const KEY_braille_dots_367: u32 = 0x1002864;
pub const KEY_braille_dots_3678: u32 = 0x10028e4;
pub const KEY_braille_dots_368: u32 = 0x10028a4;
pub const KEY_braille_dots_37: u32 = 0x1002844;
pub const KEY_braille_dots_378: u32 = 0x10028c4;
pub const KEY_braille_dots_38: u32 = 0x1002884;
pub const KEY_braille_dots_4: u32 = 0x1002808;
pub const KEY_braille_dots_45: u32 = 0x1002818;
pub const KEY_braille_dots_456: u32 = 0x1002838;
pub const KEY_braille_dots_4567: u32 = 0x1002878;
pub const KEY_braille_dots_45678: u32 = 0x10028f8;
pub const KEY_braille_dots_4568: u32 = 0x10028b8;
pub const KEY_braille_dots_457: u32 = 0x1002858;
pub const KEY_braille_dots_4578: u32 = 0x10028d8;
pub const KEY_braille_dots_458: u32 = 0x1002898;
pub const KEY_braille_dots_46: u32 = 0x1002828;
pub const KEY_braille_dots_467: u32 = 0x1002868;
pub const KEY_braille_dots_4678: u32 = 0x10028e8;
pub const KEY_braille_dots_468: u32 = 0x10028a8;
pub const KEY_braille_dots_47: u32 = 0x1002848;
pub const KEY_braille_dots_478: u32 = 0x10028c8;
pub const KEY_braille_dots_48: u32 = 0x1002888;
pub const KEY_braille_dots_5: u32 = 0x1002810;
pub const KEY_braille_dots_56: u32 = 0x1002830;
pub const KEY_braille_dots_567: u32 = 0x1002870;
pub const KEY_braille_dots_5678: u32 = 0x10028f0;
pub const KEY_braille_dots_568: u32 = 0x10028b0;
pub const KEY_braille_dots_57: u32 = 0x1002850;
pub const KEY_braille_dots_578: u32 = 0x10028d0;
pub const KEY_braille_dots_58: u32 = 0x1002890;
pub const KEY_braille_dots_6: u32 = 0x1002820;
pub const KEY_braille_dots_67: u32 = 0x1002860;
pub const KEY_braille_dots_678: u32 = 0x10028e0;
pub const KEY_braille_dots_68: u32 = 0x10028a0;
pub const KEY_braille_dots_7: u32 = 0x1002840;
pub const KEY_braille_dots_78: u32 = 0x10028c0;
pub const KEY_braille_dots_8: u32 = 0x1002880;
pub const KEY_Break: u32 = 0xff6b;
pub const KEY_breve: u32 = 0x1a2;
pub const KEY_brokenbar: u32 = 0xa6;
pub const KEY_Byelorussian_SHORTU: u32 = 0x6be;
pub const KEY_Byelorussian_shortu: u32 = 0x6ae;
pub const KEY_C: u32 = 0x43;
pub const KEY_c: u32 = 0x63;
pub const KEY_C_H: u32 = 0xfea5;
pub const KEY_C_h: u32 = 0xfea4;
pub const KEY_c_h: u32 = 0xfea3;
pub const KEY_Cabovedot: u32 = 0x2c5;
pub const KEY_cabovedot: u32 = 0x2e5;
pub const KEY_Cacute: u32 = 0x1c6;
pub const KEY_cacute: u32 = 0x1e6;
pub const KEY_Cancel: u32 = 0xff69;
pub const KEY_Caps_Lock: u32 = 0xffe5;
pub const KEY_careof: u32 = 0xab8;
pub const KEY_caret: u32 = 0xafc;
pub const KEY_caron: u32 = 0x1b7;
pub const KEY_Ccaron: u32 = 0x1c8;
pub const KEY_ccaron: u32 = 0x1e8;
pub const KEY_Ccedilla: u32 = 0xc7;
pub const KEY_ccedilla: u32 = 0xe7;
pub const KEY_Ccircumflex: u32 = 0x2c6;
pub const KEY_ccircumflex: u32 = 0x2e6;
pub const KEY_cedilla: u32 = 0xb8;
pub const KEY_cent: u32 = 0xa2;
pub const KEY_CH: u32 = 0xfea2;
pub const KEY_Ch: u32 = 0xfea1;
pub const KEY_ch: u32 = 0xfea0;
pub const KEY_checkerboard: u32 = 0x9e1;
pub const KEY_checkmark: u32 = 0xaf3;
pub const KEY_circle: u32 = 0xbcf;
pub const KEY_Clear: u32 = 0xff0b;
pub const KEY_ClearLine: u32 = 0x1000ff6f;
pub const KEY_club: u32 = 0xaec;
pub const KEY_Codeinput: u32 = 0xff37;
pub const KEY_colon: u32 = 0x3a;
pub const KEY_ColonSign: u32 = 0x10020a1;
pub const KEY_combining_acute: u32 = 0x1000301;
pub const KEY_combining_belowdot: u32 = 0x1000323;
pub const KEY_combining_grave: u32 = 0x1000300;
pub const KEY_combining_hook: u32 = 0x1000309;
pub const KEY_combining_tilde: u32 = 0x1000303;
pub const KEY_comma: u32 = 0x2c;
pub const KEY_containsas: u32 = 0x100220b;
pub const KEY_Control_L: u32 = 0xffe3;
pub const KEY_Control_R: u32 = 0xffe4;
pub const KEY_copyright: u32 = 0xa9;
pub const KEY_cr: u32 = 0x9e4;
pub const KEY_crossinglines: u32 = 0x9ee;
pub const KEY_CruzeiroSign: u32 = 0x10020a2;
pub const KEY_cuberoot: u32 = 0x100221b;
pub const KEY_currency: u32 = 0xa4;
pub const KEY_cursor: u32 = 0xaff;
pub const KEY_Cyrillic_A: u32 = 0x6e1;
pub const KEY_Cyrillic_a: u32 = 0x6c1;
pub const KEY_Cyrillic_BE: u32 = 0x6e2;
pub const KEY_Cyrillic_be: u32 = 0x6c2;
pub const KEY_Cyrillic_CHE: u32 = 0x6fe;
pub const KEY_Cyrillic_che: u32 = 0x6de;
pub const KEY_Cyrillic_CHE_descender: u32 = 0x10004b6;
pub const KEY_Cyrillic_che_descender: u32 = 0x10004b7;
pub const KEY_Cyrillic_CHE_vertstroke: u32 = 0x10004b8;
pub const KEY_Cyrillic_che_vertstroke: u32 = 0x10004b9;
pub const KEY_Cyrillic_DE: u32 = 0x6e4;
pub const KEY_Cyrillic_de: u32 = 0x6c4;
pub const KEY_Cyrillic_DZHE: u32 = 0x6bf;
pub const KEY_Cyrillic_dzhe: u32 = 0x6af;
pub const KEY_Cyrillic_E: u32 = 0x6fc;
pub const KEY_Cyrillic_e: u32 = 0x6dc;
pub const KEY_Cyrillic_EF: u32 = 0x6e6;
pub const KEY_Cyrillic_ef: u32 = 0x6c6;
pub const KEY_Cyrillic_EL: u32 = 0x6ec;
pub const KEY_Cyrillic_el: u32 = 0x6cc;
pub const KEY_Cyrillic_EM: u32 = 0x6ed;
pub const KEY_Cyrillic_em: u32 = 0x6cd;
pub const KEY_Cyrillic_EN: u32 = 0x6ee;
pub const KEY_Cyrillic_en: u32 = 0x6ce;
pub const KEY_Cyrillic_EN_descender: u32 = 0x10004a2;
pub const KEY_Cyrillic_en_descender: u32 = 0x10004a3;
pub const KEY_Cyrillic_ER: u32 = 0x6f2;
pub const KEY_Cyrillic_er: u32 = 0x6d2;
pub const KEY_Cyrillic_ES: u32 = 0x6f3;
pub const KEY_Cyrillic_es: u32 = 0x6d3;
pub const KEY_Cyrillic_GHE: u32 = 0x6e7;
pub const KEY_Cyrillic_ghe: u32 = 0x6c7;
pub const KEY_Cyrillic_GHE_bar: u32 = 0x1000492;
pub const KEY_Cyrillic_ghe_bar: u32 = 0x1000493;
pub const KEY_Cyrillic_HA: u32 = 0x6e8;
pub const KEY_Cyrillic_ha: u32 = 0x6c8;
pub const KEY_Cyrillic_HA_descender: u32 = 0x10004b2;
pub const KEY_Cyrillic_ha_descender: u32 = 0x10004b3;
pub const KEY_Cyrillic_HARDSIGN: u32 = 0x6ff;
pub const KEY_Cyrillic_hardsign: u32 = 0x6df;
pub const KEY_Cyrillic_I: u32 = 0x6e9;
pub const KEY_Cyrillic_i: u32 = 0x6c9;
pub const KEY_Cyrillic_I_macron: u32 = 0x10004e2;
pub const KEY_Cyrillic_i_macron: u32 = 0x10004e3;
pub const KEY_Cyrillic_IE: u32 = 0x6e5;
pub const KEY_Cyrillic_ie: u32 = 0x6c5;
pub const KEY_Cyrillic_IO: u32 = 0x6b3;
pub const KEY_Cyrillic_io: u32 = 0x6a3;
pub const KEY_Cyrillic_JE: u32 = 0x6b8;
pub const KEY_Cyrillic_je: u32 = 0x6a8;
pub const KEY_Cyrillic_KA: u32 = 0x6eb;
pub const KEY_Cyrillic_ka: u32 = 0x6cb;
pub const KEY_Cyrillic_KA_descender: u32 = 0x100049a;
pub const KEY_Cyrillic_ka_descender: u32 = 0x100049b;
pub const KEY_Cyrillic_KA_vertstroke: u32 = 0x100049c;
pub const KEY_Cyrillic_ka_vertstroke: u32 = 0x100049d;
pub const KEY_Cyrillic_LJE: u32 = 0x6b9;
pub const KEY_Cyrillic_lje: u32 = 0x6a9;
pub const KEY_Cyrillic_NJE: u32 = 0x6ba;
pub const KEY_Cyrillic_nje: u32 = 0x6aa;
pub const KEY_Cyrillic_O: u32 = 0x6ef;
pub const KEY_Cyrillic_o: u32 = 0x6cf;
pub const KEY_Cyrillic_O_bar: u32 = 0x10004e8;
pub const KEY_Cyrillic_o_bar: u32 = 0x10004e9;
pub const KEY_Cyrillic_PE: u32 = 0x6f0;
pub const KEY_Cyrillic_pe: u32 = 0x6d0;
pub const KEY_Cyrillic_SCHWA: u32 = 0x10004d8;
pub const KEY_Cyrillic_schwa: u32 = 0x10004d9;
pub const KEY_Cyrillic_SHA: u32 = 0x6fb;
pub const KEY_Cyrillic_sha: u32 = 0x6db;
pub const KEY_Cyrillic_SHCHA: u32 = 0x6fd;
pub const KEY_Cyrillic_shcha: u32 = 0x6dd;
pub const KEY_Cyrillic_SHHA: u32 = 0x10004ba;
pub const KEY_Cyrillic_shha: u32 = 0x10004bb;
pub const KEY_Cyrillic_SHORTI: u32 = 0x6ea;
pub const KEY_Cyrillic_shorti: u32 = 0x6ca;
pub const KEY_Cyrillic_SOFTSIGN: u32 = 0x6f8;
pub const KEY_Cyrillic_softsign: u32 = 0x6d8;
pub const KEY_Cyrillic_TE: u32 = 0x6f4;
pub const KEY_Cyrillic_te: u32 = 0x6d4;
pub const KEY_Cyrillic_TSE: u32 = 0x6e3;
pub const KEY_Cyrillic_tse: u32 = 0x6c3;
pub const KEY_Cyrillic_U: u32 = 0x6f5;
pub const KEY_Cyrillic_u: u32 = 0x6d5;
pub const KEY_Cyrillic_U_macron: u32 = 0x10004ee;
pub const KEY_Cyrillic_u_macron: u32 = 0x10004ef;
pub const KEY_Cyrillic_U_straight: u32 = 0x10004ae;
pub const KEY_Cyrillic_u_straight: u32 = 0x10004af;
pub const KEY_Cyrillic_U_straight_bar: u32 = 0x10004b0;
pub const KEY_Cyrillic_u_straight_bar: u32 = 0x10004b1;
pub const KEY_Cyrillic_VE: u32 = 0x6f7;
pub const KEY_Cyrillic_ve: u32 = 0x6d7;
pub const KEY_Cyrillic_YA: u32 = 0x6f1;
pub const KEY_Cyrillic_ya: u32 = 0x6d1;
pub const KEY_Cyrillic_YERU: u32 = 0x6f9;
pub const KEY_Cyrillic_yeru: u32 = 0x6d9;
pub const KEY_Cyrillic_YU: u32 = 0x6e0;
pub const KEY_Cyrillic_yu: u32 = 0x6c0;
pub const KEY_Cyrillic_ZE: u32 = 0x6fa;
pub const KEY_Cyrillic_ze: u32 = 0x6da;
pub const KEY_Cyrillic_ZHE: u32 = 0x6f6;
pub const KEY_Cyrillic_zhe: u32 = 0x6d6;
pub const KEY_Cyrillic_ZHE_descender: u32 = 0x1000496;
pub const KEY_Cyrillic_zhe_descender: u32 = 0x1000497;
pub const KEY_D: u32 = 0x44;
pub const KEY_d: u32 = 0x64;
pub const KEY_Dabovedot: u32 = 0x1001e0a;
pub const KEY_dabovedot: u32 = 0x1001e0b;
pub const KEY_Dacute_accent: u32 = 0x1000fe27;
pub const KEY_dagger: u32 = 0xaf1;
pub const KEY_Dcaron: u32 = 0x1cf;
pub const KEY_dcaron: u32 = 0x1ef;
pub const KEY_Dcedilla_accent: u32 = 0x1000fe2c;
pub const KEY_Dcircumflex_accent: u32 = 0x1000fe5e;
pub const KEY_Ddiaeresis: u32 = 0x1000fe22;
pub const KEY_dead_A: u32 = 0xfe81;
pub const KEY_dead_a: u32 = 0xfe80;
pub const KEY_dead_abovecomma: u32 = 0xfe64;
pub const KEY_dead_abovedot: u32 = 0xfe56;
pub const KEY_dead_abovereversedcomma: u32 = 0xfe65;
pub const KEY_dead_abovering: u32 = 0xfe58;
pub const KEY_dead_aboveverticalline: u32 = 0xfe91;
pub const KEY_dead_acute: u32 = 0xfe51;
pub const KEY_dead_belowbreve: u32 = 0xfe6b;
pub const KEY_dead_belowcircumflex: u32 = 0xfe69;
pub const KEY_dead_belowcomma: u32 = 0xfe6e;
pub const KEY_dead_belowdiaeresis: u32 = 0xfe6c;
pub const KEY_dead_belowdot: u32 = 0xfe60;
pub const KEY_dead_belowmacron: u32 = 0xfe68;
pub const KEY_dead_belowring: u32 = 0xfe67;
pub const KEY_dead_belowtilde: u32 = 0xfe6a;
pub const KEY_dead_belowverticalline: u32 = 0xfe92;
pub const KEY_dead_breve: u32 = 0xfe55;
pub const KEY_dead_capital_schwa: u32 = 0xfe8b;
pub const KEY_dead_caron: u32 = 0xfe5a;
pub const KEY_dead_cedilla: u32 = 0xfe5b;
pub const KEY_dead_circumflex: u32 = 0xfe52;
pub const KEY_dead_currency: u32 = 0xfe6f;
pub const KEY_dead_dasia: u32 = 0xfe65;
pub const KEY_dead_diaeresis: u32 = 0xfe57;
pub const KEY_dead_doubleacute: u32 = 0xfe59;
pub const KEY_dead_doublegrave: u32 = 0xfe66;
pub const KEY_dead_E: u32 = 0xfe83;
pub const KEY_dead_e: u32 = 0xfe82;
pub const KEY_dead_grave: u32 = 0xfe50;
pub const KEY_dead_greek: u32 = 0xfe8c;
pub const KEY_dead_hamza: u32 = 0xfe8d;
pub const KEY_dead_hook: u32 = 0xfe61;
pub const KEY_dead_horn: u32 = 0xfe62;
pub const KEY_dead_I: u32 = 0xfe85;
pub const KEY_dead_i: u32 = 0xfe84;
pub const KEY_dead_invertedbreve: u32 = 0xfe6d;
pub const KEY_dead_iota: u32 = 0xfe5d;
pub const KEY_dead_longsolidusoverlay: u32 = 0xfe93;
pub const KEY_dead_lowline: u32 = 0xfe90;
pub const KEY_dead_macron: u32 = 0xfe54;
pub const KEY_dead_O: u32 = 0xfe87;
pub const KEY_dead_o: u32 = 0xfe86;
pub const KEY_dead_ogonek: u32 = 0xfe5c;
pub const KEY_dead_perispomeni: u32 = 0xfe53;
pub const KEY_dead_psili: u32 = 0xfe64;
pub const KEY_dead_SCHWA: u32 = 0xfe8b;
pub const KEY_dead_schwa: u32 = 0xfe8a;
pub const KEY_dead_semivoiced_sound: u32 = 0xfe5f;
pub const KEY_dead_small_schwa: u32 = 0xfe8a;
pub const KEY_dead_stroke: u32 = 0xfe63;
pub const KEY_dead_tilde: u32 = 0xfe53;
pub const KEY_dead_U: u32 = 0xfe89;
pub const KEY_dead_u: u32 = 0xfe88;
pub const KEY_dead_voiced_sound: u32 = 0xfe5e;
pub const KEY_decimalpoint: u32 = 0xabd;
pub const KEY_degree: u32 = 0xb0;
pub const KEY_Delete: u32 = 0xffff;
pub const KEY_DeleteChar: u32 = 0x1000ff73;
pub const KEY_DeleteLine: u32 = 0x1000ff71;
pub const KEY_Dgrave_accent: u32 = 0x1000fe60;
pub const KEY_diaeresis: u32 = 0xa8;
pub const KEY_diamond: u32 = 0xaed;
pub const KEY_digitspace: u32 = 0xaa5;
pub const KEY_dintegral: u32 = 0x100222c;
pub const KEY_division: u32 = 0xf7;
pub const KEY_dollar: u32 = 0x24;
pub const KEY_DongSign: u32 = 0x10020ab;
pub const KEY_doubbaselinedot: u32 = 0xaaf;
pub const KEY_doubleacute: u32 = 0x1bd;
pub const KEY_doubledagger: u32 = 0xaf2;
pub const KEY_doublelowquotemark: u32 = 0xafe;
pub const KEY_Down: u32 = 0xff54;
pub const KEY_downarrow: u32 = 0x8fe;
pub const KEY_downcaret: u32 = 0xba8;
pub const KEY_downshoe: u32 = 0xbd6;
pub const KEY_downstile: u32 = 0xbc4;
pub const KEY_downtack: u32 = 0xbc2;
pub const KEY_DRemove: u32 = 0x1000ff00;
pub const KEY_Dring_accent: u32 = 0x1000feb0;
pub const KEY_Dstroke: u32 = 0x1d0;
pub const KEY_dstroke: u32 = 0x1f0;
pub const KEY_Dtilde: u32 = 0x1000fe7e;
pub const KEY_E: u32 = 0x45;
pub const KEY_e: u32 = 0x65;
pub const KEY_Eabovedot: u32 = 0x3cc;
pub const KEY_eabovedot: u32 = 0x3ec;
pub const KEY_Eacute: u32 = 0xc9;
pub const KEY_eacute: u32 = 0xe9;
pub const KEY_Ebelowdot: u32 = 0x1001eb8;
pub const KEY_ebelowdot: u32 = 0x1001eb9;
pub const KEY_Ecaron: u32 = 0x1cc;
pub const KEY_ecaron: u32 = 0x1ec;
pub const KEY_Ecircumflex: u32 = 0xca;
pub const KEY_ecircumflex: u32 = 0xea;
pub const KEY_Ecircumflexacute: u32 = 0x1001ebe;
pub const KEY_ecircumflexacute: u32 = 0x1001ebf;
pub const KEY_Ecircumflexbelowdot: u32 = 0x1001ec6;
pub const KEY_ecircumflexbelowdot: u32 = 0x1001ec7;
pub const KEY_Ecircumflexgrave: u32 = 0x1001ec0;
pub const KEY_ecircumflexgrave: u32 = 0x1001ec1;
pub const KEY_Ecircumflexhook: u32 = 0x1001ec2;
pub const KEY_ecircumflexhook: u32 = 0x1001ec3;
pub const KEY_Ecircumflextilde: u32 = 0x1001ec4;
pub const KEY_ecircumflextilde: u32 = 0x1001ec5;
pub const KEY_EcuSign: u32 = 0x10020a0;
pub const KEY_Ediaeresis: u32 = 0xcb;
pub const KEY_ediaeresis: u32 = 0xeb;
pub const KEY_Egrave: u32 = 0xc8;
pub const KEY_egrave: u32 = 0xe8;
pub const KEY_Ehook: u32 = 0x1001eba;
pub const KEY_ehook: u32 = 0x1001ebb;
pub const KEY_eightsubscript: u32 = 0x1002088;
pub const KEY_eightsuperior: u32 = 0x1002078;
pub const KEY_Eisu_Shift: u32 = 0xff2f;
pub const KEY_Eisu_toggle: u32 = 0xff30;
pub const KEY_elementof: u32 = 0x1002208;
pub const KEY_ellipsis: u32 = 0xaae;
pub const KEY_em3space: u32 = 0xaa3;
pub const KEY_em4space: u32 = 0xaa4;
pub const KEY_Emacron: u32 = 0x3aa;
pub const KEY_emacron: u32 = 0x3ba;
pub const KEY_emdash: u32 = 0xaa9;
pub const KEY_emfilledcircle: u32 = 0xade;
pub const KEY_emfilledrect: u32 = 0xadf;
pub const KEY_emopencircle: u32 = 0xace;
pub const KEY_emopenrectangle: u32 = 0xacf;
pub const KEY_emptyset: u32 = 0x1002205;
pub const KEY_emspace: u32 = 0xaa1;
pub const KEY_End: u32 = 0xff57;
pub const KEY_endash: u32 = 0xaaa;
pub const KEY_enfilledcircbullet: u32 = 0xae6;
pub const KEY_enfilledsqbullet: u32 = 0xae7;
pub const KEY_ENG: u32 = 0x3bd;
pub const KEY_eng: u32 = 0x3bf;
pub const KEY_enopencircbullet: u32 = 0xae0;
pub const KEY_enopensquarebullet: u32 = 0xae1;
pub const KEY_enspace: u32 = 0xaa2;
pub const KEY_Eogonek: u32 = 0x1ca;
pub const KEY_eogonek: u32 = 0x1ea;
pub const KEY_equal: u32 = 0x3d;
pub const KEY_Escape: u32 = 0xff1b;
pub const KEY_ETH: u32 = 0xd0;
pub const KEY_Eth: u32 = 0xd0;
pub const KEY_eth: u32 = 0xf0;
pub const KEY_Etilde: u32 = 0x1001ebc;
pub const KEY_etilde: u32 = 0x1001ebd;
pub const KEY_EuroSign: u32 = 0x20ac;
pub const KEY_exclam: u32 = 0x21;
pub const KEY_exclamdown: u32 = 0xa1;
pub const KEY_Execute: u32 = 0xff62;
pub const KEY_Ext16bit_L: u32 = 0x1000ff76;
pub const KEY_Ext16bit_R: u32 = 0x1000ff77;
pub const KEY_EZH: u32 = 0x10001b7;
pub const KEY_ezh: u32 = 0x1000292;
pub const KEY_F: u32 = 0x46;
pub const KEY_f: u32 = 0x66;
pub const KEY_F1: u32 = 0xffbe;
pub const KEY_F10: u32 = 0xffc7;
pub const KEY_F11: u32 = 0xffc8;
pub const KEY_F12: u32 = 0xffc9;
pub const KEY_F13: u32 = 0xffca;
pub const KEY_F14: u32 = 0xffcb;
pub const KEY_F15: u32 = 0xffcc;
pub const KEY_F16: u32 = 0xffcd;
pub const KEY_F17: u32 = 0xffce;
pub const KEY_F18: u32 = 0xffcf;
pub const KEY_F19: u32 = 0xffd0;
pub const KEY_F2: u32 = 0xffbf;
pub const KEY_F20: u32 = 0xffd1;
pub const KEY_F21: u32 = 0xffd2;
pub const KEY_F22: u32 = 0xffd3;
pub const KEY_F23: u32 = 0xffd4;
pub const KEY_F24: u32 = 0xffd5;
pub const KEY_F25: u32 = 0xffd6;
pub const KEY_F26: u32 = 0xffd7;
pub const KEY_F27: u32 = 0xffd8;
pub const KEY_F28: u32 = 0xffd9;
pub const KEY_F29: u32 = 0xffda;
pub const KEY_F3: u32 = 0xffc0;
pub const KEY_F30: u32 = 0xffdb;
pub const KEY_F31: u32 = 0xffdc;
pub const KEY_F32: u32 = 0xffdd;
pub const KEY_F33: u32 = 0xffde;
pub const KEY_F34: u32 = 0xffdf;
pub const KEY_F35: u32 = 0xffe0;
pub const KEY_F4: u32 = 0xffc1;
pub const KEY_F5: u32 = 0xffc2;
pub const KEY_F6: u32 = 0xffc3;
pub const KEY_F7: u32 = 0xffc4;
pub const KEY_F8: u32 = 0xffc5;
pub const KEY_F9: u32 = 0xffc6;
pub const KEY_Fabovedot: u32 = 0x1001e1e;
pub const KEY_fabovedot: u32 = 0x1001e1f;
pub const KEY_Farsi_0: u32 = 0x10006f0;
pub const KEY_Farsi_1: u32 = 0x10006f1;
pub const KEY_Farsi_2: u32 = 0x10006f2;
pub const KEY_Farsi_3: u32 = 0x10006f3;
pub const KEY_Farsi_4: u32 = 0x10006f4;
pub const KEY_Farsi_5: u32 = 0x10006f5;
pub const KEY_Farsi_6: u32 = 0x10006f6;
pub const KEY_Farsi_7: u32 = 0x10006f7;
pub const KEY_Farsi_8: u32 = 0x10006f8;
pub const KEY_Farsi_9: u32 = 0x10006f9;
pub const KEY_Farsi_yeh: u32 = 0x10006cc;
pub const KEY_femalesymbol: u32 = 0xaf8;
pub const KEY_ff: u32 = 0x9e3;
pub const KEY_FFrancSign: u32 = 0x10020a3;
pub const KEY_figdash: u32 = 0xabb;
pub const KEY_filledlefttribullet: u32 = 0xadc;
pub const KEY_filledrectbullet: u32 = 0xadb;
pub const KEY_filledrighttribullet: u32 = 0xadd;
pub const KEY_filledtribulletdown: u32 = 0xae9;
pub const KEY_filledtribulletup: u32 = 0xae8;
pub const KEY_Find: u32 = 0xff68;
pub const KEY_First_Virtual_Screen: u32 = 0xfed0;
pub const KEY_fiveeighths: u32 = 0xac5;
pub const KEY_fivesixths: u32 = 0xab7;
pub const KEY_fivesubscript: u32 = 0x1002085;
pub const KEY_fivesuperior: u32 = 0x1002075;
pub const KEY_fourfifths: u32 = 0xab5;
pub const KEY_foursubscript: u32 = 0x1002084;
pub const KEY_foursuperior: u32 = 0x1002074;
pub const KEY_fourthroot: u32 = 0x100221c;
pub const KEY_function: u32 = 0x8f6;
pub const KEY_G: u32 = 0x47;
pub const KEY_g: u32 = 0x67;
pub const KEY_Gabovedot: u32 = 0x2d5;
pub const KEY_gabovedot: u32 = 0x2f5;
pub const KEY_Gbreve: u32 = 0x2ab;
pub const KEY_gbreve: u32 = 0x2bb;
pub const KEY_Gcaron: u32 = 0x10001e6;
pub const KEY_gcaron: u32 = 0x10001e7;
pub const KEY_Gcedilla: u32 = 0x3ab;
pub const KEY_gcedilla: u32 = 0x3bb;
pub const KEY_Gcircumflex: u32 = 0x2d8;
pub const KEY_gcircumflex: u32 = 0x2f8;
pub const KEY_Georgian_an: u32 = 0x10010d0;
pub const KEY_Georgian_ban: u32 = 0x10010d1;
pub const KEY_Georgian_can: u32 = 0x10010ea;
pub const KEY_Georgian_char: u32 = 0x10010ed;
pub const KEY_Georgian_chin: u32 = 0x10010e9;
pub const KEY_Georgian_cil: u32 = 0x10010ec;
pub const KEY_Georgian_don: u32 = 0x10010d3;
pub const KEY_Georgian_en: u32 = 0x10010d4;
pub const KEY_Georgian_fi: u32 = 0x10010f6;
pub const KEY_Georgian_gan: u32 = 0x10010d2;
pub const KEY_Georgian_ghan: u32 = 0x10010e6;
pub const KEY_Georgian_hae: u32 = 0x10010f0;
pub const KEY_Georgian_har: u32 = 0x10010f4;
pub const KEY_Georgian_he: u32 = 0x10010f1;
pub const KEY_Georgian_hie: u32 = 0x10010f2;
pub const KEY_Georgian_hoe: u32 = 0x10010f5;
pub const KEY_Georgian_in: u32 = 0x10010d8;
pub const KEY_Georgian_jhan: u32 = 0x10010ef;
pub const KEY_Georgian_jil: u32 = 0x10010eb;
pub const KEY_Georgian_kan: u32 = 0x10010d9;
pub const KEY_Georgian_khar: u32 = 0x10010e5;
pub const KEY_Georgian_las: u32 = 0x10010da;
pub const KEY_Georgian_man: u32 = 0x10010db;
pub const KEY_Georgian_nar: u32 = 0x10010dc;
pub const KEY_Georgian_on: u32 = 0x10010dd;
pub const KEY_Georgian_par: u32 = 0x10010de;
pub const KEY_Georgian_phar: u32 = 0x10010e4;
pub const KEY_Georgian_qar: u32 = 0x10010e7;
pub const KEY_Georgian_rae: u32 = 0x10010e0;
pub const KEY_Georgian_san: u32 = 0x10010e1;
pub const KEY_Georgian_shin: u32 = 0x10010e8;
pub const KEY_Georgian_tan: u32 = 0x10010d7;
pub const KEY_Georgian_tar: u32 = 0x10010e2;
pub const KEY_Georgian_un: u32 = 0x10010e3;
pub const KEY_Georgian_vin: u32 = 0x10010d5;
pub const KEY_Georgian_we: u32 = 0x10010f3;
pub const KEY_Georgian_xan: u32 = 0x10010ee;
pub const KEY_Georgian_zen: u32 = 0x10010d6;
pub const KEY_Georgian_zhar: u32 = 0x10010df;
pub const KEY_grave: u32 = 0x60;
pub const KEY_greater: u32 = 0x3e;
pub const KEY_greaterthanequal: u32 = 0x8be;
pub const KEY_Greek_accentdieresis: u32 = 0x7ae;
pub const KEY_Greek_ALPHA: u32 = 0x7c1;
pub const KEY_Greek_alpha: u32 = 0x7e1;
pub const KEY_Greek_ALPHAaccent: u32 = 0x7a1;
pub const KEY_Greek_alphaaccent: u32 = 0x7b1;
pub const KEY_Greek_BETA: u32 = 0x7c2;
pub const KEY_Greek_beta: u32 = 0x7e2;
pub const KEY_Greek_CHI: u32 = 0x7d7;
pub const KEY_Greek_chi: u32 = 0x7f7;
pub const KEY_Greek_DELTA: u32 = 0x7c4;
pub const KEY_Greek_delta: u32 = 0x7e4;
pub const KEY_Greek_EPSILON: u32 = 0x7c5;
pub const KEY_Greek_epsilon: u32 = 0x7e5;
pub const KEY_Greek_EPSILONaccent: u32 = 0x7a2;
pub const KEY_Greek_epsilonaccent: u32 = 0x7b2;
pub const KEY_Greek_ETA: u32 = 0x7c7;
pub const KEY_Greek_eta: u32 = 0x7e7;
pub const KEY_Greek_ETAaccent: u32 = 0x7a3;
pub const KEY_Greek_etaaccent: u32 = 0x7b3;
pub const KEY_Greek_finalsmallsigma: u32 = 0x7f3;
pub const KEY_Greek_GAMMA: u32 = 0x7c3;
pub const KEY_Greek_gamma: u32 = 0x7e3;
pub const KEY_Greek_horizbar: u32 = 0x7af;
pub const KEY_Greek_IOTA: u32 = 0x7c9;
pub const KEY_Greek_iota: u32 = 0x7e9;
pub const KEY_Greek_IOTAaccent: u32 = 0x7a4;
pub const KEY_Greek_iotaaccent: u32 = 0x7b4;
pub const KEY_Greek_iotaaccentdieresis: u32 = 0x7b6;
pub const KEY_Greek_IOTAdiaeresis: u32 = 0x7a5;
pub const KEY_Greek_IOTAdieresis: u32 = 0x7a5;
pub const KEY_Greek_iotadieresis: u32 = 0x7b5;
pub const KEY_Greek_KAPPA: u32 = 0x7ca;
pub const KEY_Greek_kappa: u32 = 0x7ea;
pub const KEY_Greek_LAMBDA: u32 = 0x7cb;
pub const KEY_Greek_lambda: u32 = 0x7eb;
pub const KEY_Greek_LAMDA: u32 = 0x7cb;
pub const KEY_Greek_lamda: u32 = 0x7eb;
pub const KEY_Greek_MU: u32 = 0x7cc;
pub const KEY_Greek_mu: u32 = 0x7ec;
pub const KEY_Greek_NU: u32 = 0x7cd;
pub const KEY_Greek_nu: u32 = 0x7ed;
pub const KEY_Greek_OMEGA: u32 = 0x7d9;
pub const KEY_Greek_omega: u32 = 0x7f9;
pub const KEY_Greek_OMEGAaccent: u32 = 0x7ab;
pub const KEY_Greek_omegaaccent: u32 = 0x7bb;
pub const KEY_Greek_OMICRON: u32 = 0x7cf;
pub const KEY_Greek_omicron: u32 = 0x7ef;
pub const KEY_Greek_OMICRONaccent: u32 = 0x7a7;
pub const KEY_Greek_omicronaccent: u32 = 0x7b7;
pub const KEY_Greek_PHI: u32 = 0x7d6;
pub const KEY_Greek_phi: u32 = 0x7f6;
pub const KEY_Greek_PI: u32 = 0x7d0;
pub const KEY_Greek_pi: u32 = 0x7f0;
pub const KEY_Greek_PSI: u32 = 0x7d8;
pub const KEY_Greek_psi: u32 = 0x7f8;
pub const KEY_Greek_RHO: u32 = 0x7d1;
pub const KEY_Greek_rho: u32 = 0x7f1;
pub const KEY_Greek_SIGMA: u32 = 0x7d2;
pub const KEY_Greek_sigma: u32 = 0x7f2;
pub const KEY_Greek_switch: u32 = 0xff7e;
pub const KEY_Greek_TAU: u32 = 0x7d4;
pub const KEY_Greek_tau: u32 = 0x7f4;
pub const KEY_Greek_THETA: u32 = 0x7c8;
pub const KEY_Greek_theta: u32 = 0x7e8;
pub const KEY_Greek_UPSILON: u32 = 0x7d5;
pub const KEY_Greek_upsilon: u32 = 0x7f5;
pub const KEY_Greek_UPSILONaccent: u32 = 0x7a8;
pub const KEY_Greek_upsilonaccent: u32 = 0x7b8;
pub const KEY_Greek_upsilonaccentdieresis: u32 = 0x7ba;
pub const KEY_Greek_UPSILONdieresis: u32 = 0x7a9;
pub const KEY_Greek_upsilondieresis: u32 = 0x7b9;
pub const KEY_Greek_XI: u32 = 0x7ce;
pub const KEY_Greek_xi: u32 = 0x7ee;
pub const KEY_Greek_ZETA: u32 = 0x7c6;
pub const KEY_Greek_zeta: u32 = 0x7e6;
pub const KEY_guilder: u32 = 0x100000be;
pub const KEY_guillemetleft: u32 = 0xab;
pub const KEY_guillemetright: u32 = 0xbb;
pub const KEY_guillemotleft: u32 = 0xab;
pub const KEY_guillemotright: u32 = 0xbb;
pub const KEY_H: u32 = 0x48;
pub const KEY_h: u32 = 0x68;
pub const KEY_hairspace: u32 = 0xaa8;
pub const KEY_Hangul: u32 = 0xff31;
pub const KEY_Hangul_A: u32 = 0xebf;
pub const KEY_Hangul_AE: u32 = 0xec0;
pub const KEY_Hangul_AraeA: u32 = 0xef6;
pub const KEY_Hangul_AraeAE: u32 = 0xef7;
pub const KEY_Hangul_Banja: u32 = 0xff39;
pub const KEY_Hangul_Cieuc: u32 = 0xeba;
pub const KEY_Hangul_Codeinput: u32 = 0xff37;
pub const KEY_Hangul_Dikeud: u32 = 0xea7;
pub const KEY_Hangul_E: u32 = 0xec4;
pub const KEY_Hangul_End: u32 = 0xff33;
pub const KEY_Hangul_EO: u32 = 0xec3;
pub const KEY_Hangul_EU: u32 = 0xed1;
pub const KEY_Hangul_Hanja: u32 = 0xff34;
pub const KEY_Hangul_Hieuh: u32 = 0xebe;
pub const KEY_Hangul_I: u32 = 0xed3;
pub const KEY_Hangul_Ieung: u32 = 0xeb7;
pub const KEY_Hangul_J_Cieuc: u32 = 0xeea;
pub const KEY_Hangul_J_Dikeud: u32 = 0xeda;
pub const KEY_Hangul_J_Hieuh: u32 = 0xeee;
pub const KEY_Hangul_J_Ieung: u32 = 0xee8;
pub const KEY_Hangul_J_Jieuj: u32 = 0xee9;
pub const KEY_Hangul_J_Khieuq: u32 = 0xeeb;
pub const KEY_Hangul_J_Kiyeog: u32 = 0xed4;
pub const KEY_Hangul_J_KiyeogSios: u32 = 0xed6;
pub const KEY_Hangul_J_KkogjiDalrinIeung: u32 = 0xef9;
pub const KEY_Hangul_J_Mieum: u32 = 0xee3;
pub const KEY_Hangul_J_Nieun: u32 = 0xed7;
pub const KEY_Hangul_J_NieunHieuh: u32 = 0xed9;
pub const KEY_Hangul_J_NieunJieuj: u32 = 0xed8;
pub const KEY_Hangul_J_PanSios: u32 = 0xef8;
pub const KEY_Hangul_J_Phieuf: u32 = 0xeed;
pub const KEY_Hangul_J_Pieub: u32 = 0xee4;
pub const KEY_Hangul_J_PieubSios: u32 = 0xee5;
pub const KEY_Hangul_J_Rieul: u32 = 0xedb;
pub const KEY_Hangul_J_RieulHieuh: u32 = 0xee2;
pub const KEY_Hangul_J_RieulKiyeog: u32 = 0xedc;
pub const KEY_Hangul_J_RieulMieum: u32 = 0xedd;
pub const KEY_Hangul_J_RieulPhieuf: u32 = 0xee1;
pub const KEY_Hangul_J_RieulPieub: u32 = 0xede;
pub const KEY_Hangul_J_RieulSios: u32 = 0xedf;
pub const KEY_Hangul_J_RieulTieut: u32 = 0xee0;
pub const KEY_Hangul_J_Sios: u32 = 0xee6;
pub const KEY_Hangul_J_SsangKiyeog: u32 = 0xed5;
pub const KEY_Hangul_J_SsangSios: u32 = 0xee7;
pub const KEY_Hangul_J_Tieut: u32 = 0xeec;
pub const KEY_Hangul_J_YeorinHieuh: u32 = 0xefa;
pub const KEY_Hangul_Jamo: u32 = 0xff35;
pub const KEY_Hangul_Jeonja: u32 = 0xff38;
pub const KEY_Hangul_Jieuj: u32 = 0xeb8;
pub const KEY_Hangul_Khieuq: u32 = 0xebb;
pub const KEY_Hangul_Kiyeog: u32 = 0xea1;
pub const KEY_Hangul_KiyeogSios: u32 = 0xea3;
pub const KEY_Hangul_KkogjiDalrinIeung: u32 = 0xef3;
pub const KEY_Hangul_Mieum: u32 = 0xeb1;
pub const KEY_Hangul_MultipleCandidate: u32 = 0xff3d;
pub const KEY_Hangul_Nieun: u32 = 0xea4;
pub const KEY_Hangul_NieunHieuh: u32 = 0xea6;
pub const KEY_Hangul_NieunJieuj: u32 = 0xea5;
pub const KEY_Hangul_O: u32 = 0xec7;
pub const KEY_Hangul_OE: u32 = 0xeca;
pub const KEY_Hangul_PanSios: u32 = 0xef2;
pub const KEY_Hangul_Phieuf: u32 = 0xebd;
pub const KEY_Hangul_Pieub: u32 = 0xeb2;
pub const KEY_Hangul_PieubSios: u32 = 0xeb4;
pub const KEY_Hangul_PostHanja: u32 = 0xff3b;
pub const KEY_Hangul_PreHanja: u32 = 0xff3a;
pub const KEY_Hangul_PreviousCandidate: u32 = 0xff3e;
pub const KEY_Hangul_Rieul: u32 = 0xea9;
pub const KEY_Hangul_RieulHieuh: u32 = 0xeb0;
pub const KEY_Hangul_RieulKiyeog: u32 = 0xeaa;
pub const KEY_Hangul_RieulMieum: u32 = 0xeab;
pub const KEY_Hangul_RieulPhieuf: u32 = 0xeaf;
pub const KEY_Hangul_RieulPieub: u32 = 0xeac;
pub const KEY_Hangul_RieulSios: u32 = 0xead;
pub const KEY_Hangul_RieulTieut: u32 = 0xeae;
pub const KEY_Hangul_RieulYeorinHieuh: u32 = 0xeef;
pub const KEY_Hangul_Romaja: u32 = 0xff36;
pub const KEY_Hangul_SingleCandidate: u32 = 0xff3c;
pub const KEY_Hangul_Sios: u32 = 0xeb5;
pub const KEY_Hangul_Special: u32 = 0xff3f;
pub const KEY_Hangul_SsangDikeud: u32 = 0xea8;
pub const KEY_Hangul_SsangJieuj: u32 = 0xeb9;
pub const KEY_Hangul_SsangKiyeog: u32 = 0xea2;
pub const KEY_Hangul_SsangPieub: u32 = 0xeb3;
pub const KEY_Hangul_SsangSios: u32 = 0xeb6;
pub const KEY_Hangul_Start: u32 = 0xff32;
pub const KEY_Hangul_SunkyeongeumMieum: u32 = 0xef0;
pub const KEY_Hangul_SunkyeongeumPhieuf: u32 = 0xef4;
pub const KEY_Hangul_SunkyeongeumPieub: u32 = 0xef1;
pub const KEY_Hangul_switch: u32 = 0xff7e;
pub const KEY_Hangul_Tieut: u32 = 0xebc;
pub const KEY_Hangul_U: u32 = 0xecc;
pub const KEY_Hangul_WA: u32 = 0xec8;
pub const KEY_Hangul_WAE: u32 = 0xec9;
pub const KEY_Hangul_WE: u32 = 0xece;
pub const KEY_Hangul_WEO: u32 = 0xecd;
pub const KEY_Hangul_WI: u32 = 0xecf;
pub const KEY_Hangul_YA: u32 = 0xec1;
pub const KEY_Hangul_YAE: u32 = 0xec2;
pub const KEY_Hangul_YE: u32 = 0xec6;
pub const KEY_Hangul_YEO: u32 = 0xec5;
pub const KEY_Hangul_YeorinHieuh: u32 = 0xef5;
pub const KEY_Hangul_YI: u32 = 0xed2;
pub const KEY_Hangul_YO: u32 = 0xecb;
pub const KEY_Hangul_YU: u32 = 0xed0;
pub const KEY_Hankaku: u32 = 0xff29;
pub const KEY_Hcircumflex: u32 = 0x2a6;
pub const KEY_hcircumflex: u32 = 0x2b6;
pub const KEY_heart: u32 = 0xaee;
pub const KEY_hebrew_aleph: u32 = 0xce0;
pub const KEY_hebrew_ayin: u32 = 0xcf2;
pub const KEY_hebrew_bet: u32 = 0xce1;
pub const KEY_hebrew_beth: u32 = 0xce1;
pub const KEY_hebrew_chet: u32 = 0xce7;
pub const KEY_hebrew_dalet: u32 = 0xce3;
pub const KEY_hebrew_daleth: u32 = 0xce3;
pub const KEY_hebrew_doublelowline: u32 = 0xcdf;
pub const KEY_hebrew_finalkaph: u32 = 0xcea;
pub const KEY_hebrew_finalmem: u32 = 0xced;
pub const KEY_hebrew_finalnun: u32 = 0xcef;
pub const KEY_hebrew_finalpe: u32 = 0xcf3;
pub const KEY_hebrew_finalzade: u32 = 0xcf5;
pub const KEY_hebrew_finalzadi: u32 = 0xcf5;
pub const KEY_hebrew_gimel: u32 = 0xce2;
pub const KEY_hebrew_gimmel: u32 = 0xce2;
pub const KEY_hebrew_he: u32 = 0xce4;
pub const KEY_hebrew_het: u32 = 0xce7;
pub const KEY_hebrew_kaph: u32 = 0xceb;
pub const KEY_hebrew_kuf: u32 = 0xcf7;
pub const KEY_hebrew_lamed: u32 = 0xcec;
pub const KEY_hebrew_mem: u32 = 0xcee;
pub const KEY_hebrew_nun: u32 = 0xcf0;
pub const KEY_hebrew_pe: u32 = 0xcf4;
pub const KEY_hebrew_qoph: u32 = 0xcf7;
pub const KEY_hebrew_resh: u32 = 0xcf8;
pub const KEY_hebrew_samech: u32 = 0xcf1;
pub const KEY_hebrew_samekh: u32 = 0xcf1;
pub const KEY_hebrew_shin: u32 = 0xcf9;
pub const KEY_Hebrew_switch: u32 = 0xff7e;
pub const KEY_hebrew_taf: u32 = 0xcfa;
pub const KEY_hebrew_taw: u32 = 0xcfa;
pub const KEY_hebrew_tet: u32 = 0xce8;
pub const KEY_hebrew_teth: u32 = 0xce8;
pub const KEY_hebrew_waw: u32 = 0xce5;
pub const KEY_hebrew_yod: u32 = 0xce9;
pub const KEY_hebrew_zade: u32 = 0xcf6;
pub const KEY_hebrew_zadi: u32 = 0xcf6;
pub const KEY_hebrew_zain: u32 = 0xce6;
pub const KEY_hebrew_zayin: u32 = 0xce6;
pub const KEY_Help: u32 = 0xff6a;
pub const KEY_Henkan: u32 = 0xff23;
pub const KEY_Henkan_Mode: u32 = 0xff23;
pub const KEY_hexagram: u32 = 0xada;
pub const KEY_Hiragana: u32 = 0xff25;
pub const KEY_Hiragana_Katakana: u32 = 0xff27;
pub const KEY_Home: u32 = 0xff50;
pub const KEY_horizconnector: u32 = 0x8a3;
pub const KEY_horizlinescan1: u32 = 0x9ef;
pub const KEY_horizlinescan3: u32 = 0x9f0;
pub const KEY_horizlinescan5: u32 = 0x9f1;
pub const KEY_horizlinescan7: u32 = 0x9f2;
pub const KEY_horizlinescan9: u32 = 0x9f3;
pub const KEY_hpBackTab: u32 = 0x1000ff74;
pub const KEY_hpblock: u32 = 0x100000fc;
pub const KEY_hpClearLine: u32 = 0x1000ff6f;
pub const KEY_hpDeleteChar: u32 = 0x1000ff73;
pub const KEY_hpDeleteLine: u32 = 0x1000ff71;
pub const KEY_hpguilder: u32 = 0x100000be;
pub const KEY_hpInsertChar: u32 = 0x1000ff72;
pub const KEY_hpInsertLine: u32 = 0x1000ff70;
pub const KEY_hpIO: u32 = 0x100000ee;
pub const KEY_hpKP_BackTab: u32 = 0x1000ff75;
pub const KEY_hplira: u32 = 0x100000af;
pub const KEY_hplongminus: u32 = 0x100000f6;
pub const KEY_hpModelock1: u32 = 0x1000ff48;
pub const KEY_hpModelock2: u32 = 0x1000ff49;
pub const KEY_hpmute_acute: u32 = 0x100000a8;
pub const KEY_hpmute_asciicircum: u32 = 0x100000aa;
pub const KEY_hpmute_asciitilde: u32 = 0x100000ac;
pub const KEY_hpmute_diaeresis: u32 = 0x100000ab;
pub const KEY_hpmute_grave: u32 = 0x100000a9;
pub const KEY_hpReset: u32 = 0x1000ff6c;
pub const KEY_hpSystem: u32 = 0x1000ff6d;
pub const KEY_hpUser: u32 = 0x1000ff6e;
pub const KEY_hpYdiaeresis: u32 = 0x100000ee;
pub const KEY_Hstroke: u32 = 0x2a1;
pub const KEY_hstroke: u32 = 0x2b1;
pub const KEY_ht: u32 = 0x9e2;
pub const KEY_Hyper_L: u32 = 0xffed;
pub const KEY_Hyper_R: u32 = 0xffee;
pub const KEY_hyphen: u32 = 0xad;
pub const KEY_I: u32 = 0x49;
pub const KEY_i: u32 = 0x69;
pub const KEY_Iabovedot: u32 = 0x2a9;
pub const KEY_Iacute: u32 = 0xcd;
pub const KEY_iacute: u32 = 0xed;
pub const KEY_Ibelowdot: u32 = 0x1001eca;
pub const KEY_ibelowdot: u32 = 0x1001ecb;
pub const KEY_Ibreve: u32 = 0x100012c;
pub const KEY_ibreve: u32 = 0x100012d;
pub const KEY_Icircumflex: u32 = 0xce;
pub const KEY_icircumflex: u32 = 0xee;
pub const KEY_identical: u32 = 0x8cf;
pub const KEY_Idiaeresis: u32 = 0xcf;
pub const KEY_idiaeresis: u32 = 0xef;
pub const KEY_idotless: u32 = 0x2b9;
pub const KEY_ifonlyif: u32 = 0x8cd;
pub const KEY_Igrave: u32 = 0xcc;
pub const KEY_igrave: u32 = 0xec;
pub const KEY_Ihook: u32 = 0x1001ec8;
pub const KEY_ihook: u32 = 0x1001ec9;
pub const KEY_Imacron: u32 = 0x3cf;
pub const KEY_imacron: u32 = 0x3ef;
pub const KEY_implies: u32 = 0x8ce;
pub const KEY_includedin: u32 = 0x8da;
pub const KEY_includes: u32 = 0x8db;
pub const KEY_infinity: u32 = 0x8c2;
pub const KEY_Insert: u32 = 0xff63;
pub const KEY_InsertChar: u32 = 0x1000ff72;
pub const KEY_InsertLine: u32 = 0x1000ff70;
pub const KEY_integral: u32 = 0x8bf;
pub const KEY_intersection: u32 = 0x8dc;
pub const KEY_IO: u32 = 0x100000ee;
pub const KEY_Iogonek: u32 = 0x3c7;
pub const KEY_iogonek: u32 = 0x3e7;
pub const KEY_ISO_Center_Object: u32 = 0xfe33;
pub const KEY_ISO_Continuous_Underline: u32 = 0xfe30;
pub const KEY_ISO_Discontinuous_Underline: u32 = 0xfe31;
pub const KEY_ISO_Emphasize: u32 = 0xfe32;
pub const KEY_ISO_Enter: u32 = 0xfe34;
pub const KEY_ISO_Fast_Cursor_Down: u32 = 0xfe2f;
pub const KEY_ISO_Fast_Cursor_Left: u32 = 0xfe2c;
pub const KEY_ISO_Fast_Cursor_Right: u32 = 0xfe2d;
pub const KEY_ISO_Fast_Cursor_Up: u32 = 0xfe2e;
pub const KEY_ISO_First_Group: u32 = 0xfe0c;
pub const KEY_ISO_First_Group_Lock: u32 = 0xfe0d;
pub const KEY_ISO_Group_Latch: u32 = 0xfe06;
pub const KEY_ISO_Group_Lock: u32 = 0xfe07;
pub const KEY_ISO_Group_Shift: u32 = 0xff7e;
pub const KEY_ISO_Last_Group: u32 = 0xfe0e;
pub const KEY_ISO_Last_Group_Lock: u32 = 0xfe0f;
pub const KEY_ISO_Left_Tab: u32 = 0xfe20;
pub const KEY_ISO_Level2_Latch: u32 = 0xfe02;
pub const KEY_ISO_Level3_Latch: u32 = 0xfe04;
pub const KEY_ISO_Level3_Lock: u32 = 0xfe05;
pub const KEY_ISO_Level3_Shift: u32 = 0xfe03;
pub const KEY_ISO_Level5_Latch: u32 = 0xfe12;
pub const KEY_ISO_Level5_Lock: u32 = 0xfe13;
pub const KEY_ISO_Level5_Shift: u32 = 0xfe11;
pub const KEY_ISO_Lock: u32 = 0xfe01;
pub const KEY_ISO_Move_Line_Down: u32 = 0xfe22;
pub const KEY_ISO_Move_Line_Up: u32 = 0xfe21;
pub const KEY_ISO_Next_Group: u32 = 0xfe08;
pub const KEY_ISO_Next_Group_Lock: u32 = 0xfe09;
pub const KEY_ISO_Partial_Line_Down: u32 = 0xfe24;
pub const KEY_ISO_Partial_Line_Up: u32 = 0xfe23;
pub const KEY_ISO_Partial_Space_Left: u32 = 0xfe25;
pub const KEY_ISO_Partial_Space_Right: u32 = 0xfe26;
pub const KEY_ISO_Prev_Group: u32 = 0xfe0a;
pub const KEY_ISO_Prev_Group_Lock: u32 = 0xfe0b;
pub const KEY_ISO_Release_Both_Margins: u32 = 0xfe2b;
pub const KEY_ISO_Release_Margin_Left: u32 = 0xfe29;
pub const KEY_ISO_Release_Margin_Right: u32 = 0xfe2a;
pub const KEY_ISO_Set_Margin_Left: u32 = 0xfe27;
pub const KEY_ISO_Set_Margin_Right: u32 = 0xfe28;
pub const KEY_Itilde: u32 = 0x3a5;
pub const KEY_itilde: u32 = 0x3b5;
pub const KEY_J: u32 = 0x4a;
pub const KEY_j: u32 = 0x6a;
pub const KEY_Jcircumflex: u32 = 0x2ac;
pub const KEY_jcircumflex: u32 = 0x2bc;
pub const KEY_jot: u32 = 0xbca;
pub const KEY_K: u32 = 0x4b;
pub const KEY_k: u32 = 0x6b;
pub const KEY_kana_A: u32 = 0x4b1;
pub const KEY_kana_a: u32 = 0x4a7;
pub const KEY_kana_CHI: u32 = 0x4c1;
pub const KEY_kana_closingbracket: u32 = 0x4a3;
pub const KEY_kana_comma: u32 = 0x4a4;
pub const KEY_kana_conjunctive: u32 = 0x4a5;
pub const KEY_kana_E: u32 = 0x4b4;
pub const KEY_kana_e: u32 = 0x4aa;
pub const KEY_kana_FU: u32 = 0x4cc;
pub const KEY_kana_fullstop: u32 = 0x4a1;
pub const KEY_kana_HA: u32 = 0x4ca;
pub const KEY_kana_HE: u32 = 0x4cd;
pub const KEY_kana_HI: u32 = 0x4cb;
pub const KEY_kana_HO: u32 = 0x4ce;
pub const KEY_kana_HU: u32 = 0x4cc;
pub const KEY_kana_I: u32 = 0x4b2;
pub const KEY_kana_i: u32 = 0x4a8;
pub const KEY_kana_KA: u32 = 0x4b6;
pub const KEY_kana_KE: u32 = 0x4b9;
pub const KEY_kana_KI: u32 = 0x4b7;
pub const KEY_kana_KO: u32 = 0x4ba;
pub const KEY_kana_KU: u32 = 0x4b8;
pub const KEY_Kana_Lock: u32 = 0xff2d;
pub const KEY_kana_MA: u32 = 0x4cf;
pub const KEY_kana_ME: u32 = 0x4d2;
pub const KEY_kana_MI: u32 = 0x4d0;
pub const KEY_kana_middledot: u32 = 0x4a5;
pub const KEY_kana_MO: u32 = 0x4d3;
pub const KEY_kana_MU: u32 = 0x4d1;
pub const KEY_kana_N: u32 = 0x4dd;
pub const KEY_kana_NA: u32 = 0x4c5;
pub const KEY_kana_NE: u32 = 0x4c8;
pub const KEY_kana_NI: u32 = 0x4c6;
pub const KEY_kana_NO: u32 = 0x4c9;
pub const KEY_kana_NU: u32 = 0x4c7;
pub const KEY_kana_O: u32 = 0x4b5;
pub const KEY_kana_o: u32 = 0x4ab;
pub const KEY_kana_openingbracket: u32 = 0x4a2;
pub const KEY_kana_RA: u32 = 0x4d7;
pub const KEY_kana_RE: u32 = 0x4da;
pub const KEY_kana_RI: u32 = 0x4d8;
pub const KEY_kana_RO: u32 = 0x4db;
pub const KEY_kana_RU: u32 = 0x4d9;
pub const KEY_kana_SA: u32 = 0x4bb;
pub const KEY_kana_SE: u32 = 0x4be;
pub const KEY_kana_SHI: u32 = 0x4bc;
pub const KEY_Kana_Shift: u32 = 0xff2e;
pub const KEY_kana_SO: u32 = 0x4bf;
pub const KEY_kana_SU: u32 = 0x4bd;
pub const KEY_kana_switch: u32 = 0xff7e;
pub const KEY_kana_TA: u32 = 0x4c0;
pub const KEY_kana_TE: u32 = 0x4c3;
pub const KEY_kana_TI: u32 = 0x4c1;
pub const KEY_kana_TO: u32 = 0x4c4;
pub const KEY_kana_TSU: u32 = 0x4c2;
pub const KEY_kana_tsu: u32 = 0x4af;
pub const KEY_kana_TU: u32 = 0x4c2;
pub const KEY_kana_tu: u32 = 0x4af;
pub const KEY_kana_U: u32 = 0x4b3;
pub const KEY_kana_u: u32 = 0x4a9;
pub const KEY_kana_WA: u32 = 0x4dc;
pub const KEY_kana_WO: u32 = 0x4a6;
pub const KEY_kana_YA: u32 = 0x4d4;
pub const KEY_kana_ya: u32 = 0x4ac;
pub const KEY_kana_YO: u32 = 0x4d6;
pub const KEY_kana_yo: u32 = 0x4ae;
pub const KEY_kana_YU: u32 = 0x4d5;
pub const KEY_kana_yu: u32 = 0x4ad;
pub const KEY_Kanji: u32 = 0xff21;
pub const KEY_Kanji_Bangou: u32 = 0xff37;
pub const KEY_kappa: u32 = 0x3a2;
pub const KEY_Katakana: u32 = 0xff26;
pub const KEY_Kcedilla: u32 = 0x3d3;
pub const KEY_kcedilla: u32 = 0x3f3;
pub const KEY_Korean_Won: u32 = 0xeff;
pub const KEY_KP_0: u32 = 0xffb0;
pub const KEY_KP_1: u32 = 0xffb1;
pub const KEY_KP_2: u32 = 0xffb2;
pub const KEY_KP_3: u32 = 0xffb3;
pub const KEY_KP_4: u32 = 0xffb4;
pub const KEY_KP_5: u32 = 0xffb5;
pub const KEY_KP_6: u32 = 0xffb6;
pub const KEY_KP_7: u32 = 0xffb7;
pub const KEY_KP_8: u32 = 0xffb8;
pub const KEY_KP_9: u32 = 0xffb9;
pub const KEY_KP_Add: u32 = 0xffab;
pub const KEY_KP_BackTab: u32 = 0x1000ff75;
pub const KEY_KP_Begin: u32 = 0xff9d;
pub const KEY_KP_Decimal: u32 = 0xffae;
pub const KEY_KP_Delete: u32 = 0xff9f;
pub const KEY_KP_Divide: u32 = 0xffaf;
pub const KEY_KP_Down: u32 = 0xff99;
pub const KEY_KP_End: u32 = 0xff9c;
pub const KEY_KP_Enter: u32 = 0xff8d;
pub const KEY_KP_Equal: u32 = 0xffbd;
pub const KEY_KP_F1: u32 = 0xff91;
pub const KEY_KP_F2: u32 = 0xff92;
pub const KEY_KP_F3: u32 = 0xff93;
pub const KEY_KP_F4: u32 = 0xff94;
pub const KEY_KP_Home: u32 = 0xff95;
pub const KEY_KP_Insert: u32 = 0xff9e;
pub const KEY_KP_Left: u32 = 0xff96;
pub const KEY_KP_Multiply: u32 = 0xffaa;
pub const KEY_KP_Next: u32 = 0xff9b;
pub const KEY_KP_Page_Down: u32 = 0xff9b;
pub const KEY_KP_Page_Up: u32 = 0xff9a;
pub const KEY_KP_Prior: u32 = 0xff9a;
pub const KEY_KP_Right: u32 = 0xff98;
pub const KEY_KP_Separator: u32 = 0xffac;
pub const KEY_KP_Space: u32 = 0xff80;
pub const KEY_KP_Subtract: u32 = 0xffad;
pub const KEY_KP_Tab: u32 = 0xff89;
pub const KEY_KP_Up: u32 = 0xff97;
pub const KEY_kra: u32 = 0x3a2;
pub const KEY_L: u32 = 0x4c;
pub const KEY_l: u32 = 0x6c;
pub const KEY_L1: u32 = 0xffc8;
pub const KEY_L10: u32 = 0xffd1;
pub const KEY_L2: u32 = 0xffc9;
pub const KEY_L3: u32 = 0xffca;
pub const KEY_L4: u32 = 0xffcb;
pub const KEY_L5: u32 = 0xffcc;
pub const KEY_L6: u32 = 0xffcd;
pub const KEY_L7: u32 = 0xffce;
pub const KEY_L8: u32 = 0xffcf;
pub const KEY_L9: u32 = 0xffd0;
pub const KEY_Lacute: u32 = 0x1c5;
pub const KEY_lacute: u32 = 0x1e5;
pub const KEY_Last_Virtual_Screen: u32 = 0xfed4;
pub const KEY_latincross: u32 = 0xad9;
pub const KEY_Lbelowdot: u32 = 0x1001e36;
pub const KEY_lbelowdot: u32 = 0x1001e37;
pub const KEY_Lcaron: u32 = 0x1a5;
pub const KEY_lcaron: u32 = 0x1b5;
pub const KEY_Lcedilla: u32 = 0x3a6;
pub const KEY_lcedilla: u32 = 0x3b6;
pub const KEY_Left: u32 = 0xff51;
pub const KEY_leftanglebracket: u32 = 0xabc;
pub const KEY_leftarrow: u32 = 0x8fb;
pub const KEY_leftcaret: u32 = 0xba3;
pub const KEY_leftdoublequotemark: u32 = 0xad2;
pub const KEY_leftmiddlecurlybrace: u32 = 0x8af;
pub const KEY_leftopentriangle: u32 = 0xacc;
pub const KEY_leftpointer: u32 = 0xaea;
pub const KEY_leftradical: u32 = 0x8a1;
pub const KEY_leftshoe: u32 = 0xbda;
pub const KEY_leftsinglequotemark: u32 = 0xad0;
pub const KEY_leftt: u32 = 0x9f4;
pub const KEY_lefttack: u32 = 0xbdc;
pub const KEY_less: u32 = 0x3c;
pub const KEY_lessthanequal: u32 = 0x8bc;
pub const KEY_lf: u32 = 0x9e5;
pub const KEY_Linefeed: u32 = 0xff0a;
pub const KEY_lira: u32 = 0x100000af;
pub const KEY_LiraSign: u32 = 0x10020a4;
pub const KEY_logicaland: u32 = 0x8de;
pub const KEY_logicalor: u32 = 0x8df;
pub const KEY_longminus: u32 = 0x100000f6;
pub const KEY_lowleftcorner: u32 = 0x9ed;
pub const KEY_lowrightcorner: u32 = 0x9ea;
pub const KEY_Lstroke: u32 = 0x1a3;
pub const KEY_lstroke: u32 = 0x1b3;
pub const KEY_M: u32 = 0x4d;
pub const KEY_m: u32 = 0x6d;
pub const KEY_Mabovedot: u32 = 0x1001e40;
pub const KEY_mabovedot: u32 = 0x1001e41;
pub const KEY_Macedonia_DSE: u32 = 0x6b5;
pub const KEY_Macedonia_dse: u32 = 0x6a5;
pub const KEY_Macedonia_GJE: u32 = 0x6b2;
pub const KEY_Macedonia_gje: u32 = 0x6a2;
pub const KEY_Macedonia_KJE: u32 = 0x6bc;
pub const KEY_Macedonia_kje: u32 = 0x6ac;
pub const KEY_macron: u32 = 0xaf;
pub const KEY_Mae_Koho: u32 = 0xff3e;
pub const KEY_malesymbol: u32 = 0xaf7;
pub const KEY_maltesecross: u32 = 0xaf0;
pub const KEY_marker: u32 = 0xabf;
pub const KEY_masculine: u32 = 0xba;
pub const KEY_Massyo: u32 = 0xff2c;
pub const KEY_Menu: u32 = 0xff67;
pub const KEY_Meta_L: u32 = 0xffe7;
pub const KEY_Meta_R: u32 = 0xffe8;
pub const KEY_MillSign: u32 = 0x10020a5;
pub const KEY_minus: u32 = 0x2d;
pub const KEY_minutes: u32 = 0xad6;
pub const KEY_Mode_switch: u32 = 0xff7e;
pub const KEY_MouseKeys_Accel_Enable: u32 = 0xfe77;
pub const KEY_MouseKeys_Enable: u32 = 0xfe76;
pub const KEY_mu: u32 = 0xb5;
pub const KEY_Muhenkan: u32 = 0xff22;
pub const KEY_Multi_key: u32 = 0xff20;
pub const KEY_MultipleCandidate: u32 = 0xff3d;
pub const KEY_multiply: u32 = 0xd7;
pub const KEY_musicalflat: u32 = 0xaf6;
pub const KEY_musicalsharp: u32 = 0xaf5;
pub const KEY_mute_acute: u32 = 0x100000a8;
pub const KEY_mute_asciicircum: u32 = 0x100000aa;
pub const KEY_mute_asciitilde: u32 = 0x100000ac;
pub const KEY_mute_diaeresis: u32 = 0x100000ab;
pub const KEY_mute_grave: u32 = 0x100000a9;
pub const KEY_N: u32 = 0x4e;
pub const KEY_n: u32 = 0x6e;
pub const KEY_nabla: u32 = 0x8c5;
pub const KEY_Nacute: u32 = 0x1d1;
pub const KEY_nacute: u32 = 0x1f1;
pub const KEY_NairaSign: u32 = 0x10020a6;
pub const KEY_Ncaron: u32 = 0x1d2;
pub const KEY_ncaron: u32 = 0x1f2;
pub const KEY_Ncedilla: u32 = 0x3d1;
pub const KEY_ncedilla: u32 = 0x3f1;
pub const KEY_NewSheqelSign: u32 = 0x10020aa;
pub const KEY_Next: u32 = 0xff56;
pub const KEY_Next_Virtual_Screen: u32 = 0xfed2;
pub const KEY_ninesubscript: u32 = 0x1002089;
pub const KEY_ninesuperior: u32 = 0x1002079;
pub const KEY_nl: u32 = 0x9e8;
pub const KEY_nobreakspace: u32 = 0xa0;
pub const KEY_NoSymbol: u32 = 0x0;
pub const KEY_notapproxeq: u32 = 0x1002247;
pub const KEY_notelementof: u32 = 0x1002209;
pub const KEY_notequal: u32 = 0x8bd;
pub const KEY_notidentical: u32 = 0x1002262;
pub const KEY_notsign: u32 = 0xac;
pub const KEY_Ntilde: u32 = 0xd1;
pub const KEY_ntilde: u32 = 0xf1;
pub const KEY_Num_Lock: u32 = 0xff7f;
pub const KEY_numbersign: u32 = 0x23;
pub const KEY_numerosign: u32 = 0x6b0;
pub const KEY_O: u32 = 0x4f;
pub const KEY_o: u32 = 0x6f;
pub const KEY_Oacute: u32 = 0xd3;
pub const KEY_oacute: u32 = 0xf3;
pub const KEY_Obarred: u32 = 0x100019f;
pub const KEY_obarred: u32 = 0x1000275;
pub const KEY_Obelowdot: u32 = 0x1001ecc;
pub const KEY_obelowdot: u32 = 0x1001ecd;
pub const KEY_Ocaron: u32 = 0x10001d1;
pub const KEY_ocaron: u32 = 0x10001d2;
pub const KEY_Ocircumflex: u32 = 0xd4;
pub const KEY_ocircumflex: u32 = 0xf4;
pub const KEY_Ocircumflexacute: u32 = 0x1001ed0;
pub const KEY_ocircumflexacute: u32 = 0x1001ed1;
pub const KEY_Ocircumflexbelowdot: u32 = 0x1001ed8;
pub const KEY_ocircumflexbelowdot: u32 = 0x1001ed9;
pub const KEY_Ocircumflexgrave: u32 = 0x1001ed2;
pub const KEY_ocircumflexgrave: u32 = 0x1001ed3;
pub const KEY_Ocircumflexhook: u32 = 0x1001ed4;
pub const KEY_ocircumflexhook: u32 = 0x1001ed5;
pub const KEY_Ocircumflextilde: u32 = 0x1001ed6;
pub const KEY_ocircumflextilde: u32 = 0x1001ed7;
pub const KEY_Odiaeresis: u32 = 0xd6;
pub const KEY_odiaeresis: u32 = 0xf6;
pub const KEY_Odoubleacute: u32 = 0x1d5;
pub const KEY_odoubleacute: u32 = 0x1f5;
pub const KEY_OE: u32 = 0x13bc;
pub const KEY_oe: u32 = 0x13bd;
pub const KEY_ogonek: u32 = 0x1b2;
pub const KEY_Ograve: u32 = 0xd2;
pub const KEY_ograve: u32 = 0xf2;
pub const KEY_Ohook: u32 = 0x1001ece;
pub const KEY_ohook: u32 = 0x1001ecf;
pub const KEY_Ohorn: u32 = 0x10001a0;
pub const KEY_ohorn: u32 = 0x10001a1;
pub const KEY_Ohornacute: u32 = 0x1001eda;
pub const KEY_ohornacute: u32 = 0x1001edb;
pub const KEY_Ohornbelowdot: u32 = 0x1001ee2;
pub const KEY_ohornbelowdot: u32 = 0x1001ee3;
pub const KEY_Ohorngrave: u32 = 0x1001edc;
pub const KEY_ohorngrave: u32 = 0x1001edd;
pub const KEY_Ohornhook: u32 = 0x1001ede;
pub const KEY_ohornhook: u32 = 0x1001edf;
pub const KEY_Ohorntilde: u32 = 0x1001ee0;
pub const KEY_ohorntilde: u32 = 0x1001ee1;
pub const KEY_Omacron: u32 = 0x3d2;
pub const KEY_omacron: u32 = 0x3f2;
pub const KEY_oneeighth: u32 = 0xac3;
pub const KEY_onefifth: u32 = 0xab2;
pub const KEY_onehalf: u32 = 0xbd;
pub const KEY_onequarter: u32 = 0xbc;
pub const KEY_onesixth: u32 = 0xab6;
pub const KEY_onesubscript: u32 = 0x1002081;
pub const KEY_onesuperior: u32 = 0xb9;
pub const KEY_onethird: u32 = 0xab0;
pub const KEY_Ooblique: u32 = 0xd8;
pub const KEY_ooblique: u32 = 0xf8;
pub const KEY_openrectbullet: u32 = 0xae2;
pub const KEY_openstar: u32 = 0xae5;
pub const KEY_opentribulletdown: u32 = 0xae4;
pub const KEY_opentribulletup: u32 = 0xae3;
pub const KEY_ordfeminine: u32 = 0xaa;
pub const KEY_ordmasculine: u32 = 0xba;
pub const KEY_osfActivate: u32 = 0x1004ff44;
pub const KEY_osfAddMode: u32 = 0x1004ff31;
pub const KEY_osfBackSpace: u32 = 0x1004ff08;
pub const KEY_osfBackTab: u32 = 0x1004ff07;
pub const KEY_osfBeginData: u32 = 0x1004ff5a;
pub const KEY_osfBeginLine: u32 = 0x1004ff58;
pub const KEY_osfCancel: u32 = 0x1004ff69;
pub const KEY_osfClear: u32 = 0x1004ff0b;
pub const KEY_osfCopy: u32 = 0x1004ff02;
pub const KEY_osfCut: u32 = 0x1004ff03;
pub const KEY_osfDelete: u32 = 0x1004ffff;
pub const KEY_osfDeselectAll: u32 = 0x1004ff72;
pub const KEY_osfDown: u32 = 0x1004ff54;
pub const KEY_osfEndData: u32 = 0x1004ff59;
pub const KEY_osfEndLine: u32 = 0x1004ff57;
pub const KEY_osfEscape: u32 = 0x1004ff1b;
pub const KEY_osfExtend: u32 = 0x1004ff74;
pub const KEY_osfHelp: u32 = 0x1004ff6a;
pub const KEY_osfInsert: u32 = 0x1004ff63;
pub const KEY_osfLeft: u32 = 0x1004ff51;
pub const KEY_osfMenu: u32 = 0x1004ff67;
pub const KEY_osfMenuBar: u32 = 0x1004ff45;
pub const KEY_osfNextField: u32 = 0x1004ff5e;
pub const KEY_osfNextMenu: u32 = 0x1004ff5c;
pub const KEY_osfPageDown: u32 = 0x1004ff42;
pub const KEY_osfPageLeft: u32 = 0x1004ff40;
pub const KEY_osfPageRight: u32 = 0x1004ff43;
pub const KEY_osfPageUp: u32 = 0x1004ff41;
pub const KEY_osfPaste: u32 = 0x1004ff04;
pub const KEY_osfPrevField: u32 = 0x1004ff5d;
pub const KEY_osfPrevMenu: u32 = 0x1004ff5b;
pub const KEY_osfPrimaryPaste: u32 = 0x1004ff32;
pub const KEY_osfQuickPaste: u32 = 0x1004ff33;
pub const KEY_osfReselect: u32 = 0x1004ff73;
pub const KEY_osfRestore: u32 = 0x1004ff78;
pub const KEY_osfRight: u32 = 0x1004ff53;
pub const KEY_osfSelect: u32 = 0x1004ff60;
pub const KEY_osfSelectAll: u32 = 0x1004ff71;
pub const KEY_osfUndo: u32 = 0x1004ff65;
pub const KEY_osfUp: u32 = 0x1004ff52;
pub const KEY_Oslash: u32 = 0xd8;
pub const KEY_oslash: u32 = 0xf8;
pub const KEY_Otilde: u32 = 0xd5;
pub const KEY_otilde: u32 = 0xf5;
pub const KEY_overbar: u32 = 0xbc0;
pub const KEY_Overlay1_Enable: u32 = 0xfe78;
pub const KEY_Overlay2_Enable: u32 = 0xfe79;
pub const KEY_overline: u32 = 0x47e;
pub const KEY_P: u32 = 0x50;
pub const KEY_p: u32 = 0x70;
pub const KEY_Pabovedot: u32 = 0x1001e56;
pub const KEY_pabovedot: u32 = 0x1001e57;
pub const KEY_Page_Down: u32 = 0xff56;
pub const KEY_Page_Up: u32 = 0xff55;
pub const KEY_paragraph: u32 = 0xb6;
pub const KEY_parenleft: u32 = 0x28;
pub const KEY_parenright: u32 = 0x29;
pub const KEY_partdifferential: u32 = 0x1002202;
pub const KEY_partialderivative: u32 = 0x8ef;
pub const KEY_Pause: u32 = 0xff13;
pub const KEY_percent: u32 = 0x25;
pub const KEY_period: u32 = 0x2e;
pub const KEY_periodcentered: u32 = 0xb7;
pub const KEY_permille: u32 = 0xad5;
pub const KEY_PesetaSign: u32 = 0x10020a7;
pub const KEY_phonographcopyright: u32 = 0xafb;
pub const KEY_plus: u32 = 0x2b;
pub const KEY_plusminus: u32 = 0xb1;
pub const KEY_Pointer_Accelerate: u32 = 0xfefa;
pub const KEY_Pointer_Button1: u32 = 0xfee9;
pub const KEY_Pointer_Button2: u32 = 0xfeea;
pub const KEY_Pointer_Button3: u32 = 0xfeeb;
pub const KEY_Pointer_Button4: u32 = 0xfeec;
pub const KEY_Pointer_Button5: u32 = 0xfeed;
pub const KEY_Pointer_Button_Dflt: u32 = 0xfee8;
pub const KEY_Pointer_DblClick1: u32 = 0xfeef;
pub const KEY_Pointer_DblClick2: u32 = 0xfef0;
pub const KEY_Pointer_DblClick3: u32 = 0xfef1;
pub const KEY_Pointer_DblClick4: u32 = 0xfef2;
pub const KEY_Pointer_DblClick5: u32 = 0xfef3;
pub const KEY_Pointer_DblClick_Dflt: u32 = 0xfeee;
pub const KEY_Pointer_DfltBtnNext: u32 = 0xfefb;
pub const KEY_Pointer_DfltBtnPrev: u32 = 0xfefc;
pub const KEY_Pointer_Down: u32 = 0xfee3;
pub const KEY_Pointer_DownLeft: u32 = 0xfee6;
pub const KEY_Pointer_DownRight: u32 = 0xfee7;
pub const KEY_Pointer_Drag1: u32 = 0xfef5;
pub const KEY_Pointer_Drag2: u32 = 0xfef6;
pub const KEY_Pointer_Drag3: u32 = 0xfef7;
pub const KEY_Pointer_Drag4: u32 = 0xfef8;
pub const KEY_Pointer_Drag5: u32 = 0xfefd;
pub const KEY_Pointer_Drag_Dflt: u32 = 0xfef4;
pub const KEY_Pointer_EnableKeys: u32 = 0xfef9;
pub const KEY_Pointer_Left: u32 = 0xfee0;
pub const KEY_Pointer_Right: u32 = 0xfee1;
pub const KEY_Pointer_Up: u32 = 0xfee2;
pub const KEY_Pointer_UpLeft: u32 = 0xfee4;
pub const KEY_Pointer_UpRight: u32 = 0xfee5;
pub const KEY_prescription: u32 = 0xad4;
pub const KEY_Prev_Virtual_Screen: u32 = 0xfed1;
pub const KEY_PreviousCandidate: u32 = 0xff3e;
pub const KEY_Print: u32 = 0xff61;
pub const KEY_Prior: u32 = 0xff55;
pub const KEY_prolongedsound: u32 = 0x4b0;
pub const KEY_punctspace: u32 = 0xaa6;
pub const KEY_Q: u32 = 0x51;
pub const KEY_q: u32 = 0x71;
pub const KEY_quad: u32 = 0xbcc;
pub const KEY_question: u32 = 0x3f;
pub const KEY_questiondown: u32 = 0xbf;
pub const KEY_quotedbl: u32 = 0x22;
pub const KEY_quoteleft: u32 = 0x60;
pub const KEY_quoteright: u32 = 0x27;
pub const KEY_R: u32 = 0x52;
pub const KEY_r: u32 = 0x72;
pub const KEY_R1: u32 = 0xffd2;
pub const KEY_R10: u32 = 0xffdb;
pub const KEY_R11: u32 = 0xffdc;
pub const KEY_R12: u32 = 0xffdd;
pub const KEY_R13: u32 = 0xffde;
pub const KEY_R14: u32 = 0xffdf;
pub const KEY_R15: u32 = 0xffe0;
pub const KEY_R2: u32 = 0xffd3;
pub const KEY_R3: u32 = 0xffd4;
pub const KEY_R4: u32 = 0xffd5;
pub const KEY_R5: u32 = 0xffd6;
pub const KEY_R6: u32 = 0xffd7;
pub const KEY_R7: u32 = 0xffd8;
pub const KEY_R8: u32 = 0xffd9;
pub const KEY_R9: u32 = 0xffda;
pub const KEY_Racute: u32 = 0x1c0;
pub const KEY_racute: u32 = 0x1e0;
pub const KEY_radical: u32 = 0x8d6;
pub const KEY_Rcaron: u32 = 0x1d8;
pub const KEY_rcaron: u32 = 0x1f8;
pub const KEY_Rcedilla: u32 = 0x3a3;
pub const KEY_rcedilla: u32 = 0x3b3;
pub const KEY_Redo: u32 = 0xff66;
pub const KEY_registered: u32 = 0xae;
pub const KEY_RepeatKeys_Enable: u32 = 0xfe72;
pub const KEY_Reset: u32 = 0x1000ff6c;
pub const KEY_Return: u32 = 0xff0d;
pub const KEY_Right: u32 = 0xff53;
pub const KEY_rightanglebracket: u32 = 0xabe;
pub const KEY_rightarrow: u32 = 0x8fd;
pub const KEY_rightcaret: u32 = 0xba6;
pub const KEY_rightdoublequotemark: u32 = 0xad3;
pub const KEY_rightmiddlecurlybrace: u32 = 0x8b0;
pub const KEY_rightmiddlesummation: u32 = 0x8b7;
pub const KEY_rightopentriangle: u32 = 0xacd;
pub const KEY_rightpointer: u32 = 0xaeb;
pub const KEY_rightshoe: u32 = 0xbd8;
pub const KEY_rightsinglequotemark: u32 = 0xad1;
pub const KEY_rightt: u32 = 0x9f5;
pub const KEY_righttack: u32 = 0xbfc;
pub const KEY_Romaji: u32 = 0xff24;
pub const KEY_RupeeSign: u32 = 0x10020a8;
pub const KEY_S: u32 = 0x53;
pub const KEY_s: u32 = 0x73;
pub const KEY_Sabovedot: u32 = 0x1001e60;
pub const KEY_sabovedot: u32 = 0x1001e61;
pub const KEY_Sacute: u32 = 0x1a6;
pub const KEY_sacute: u32 = 0x1b6;
pub const KEY_Scaron: u32 = 0x1a9;
pub const KEY_scaron: u32 = 0x1b9;
pub const KEY_Scedilla: u32 = 0x1aa;
pub const KEY_scedilla: u32 = 0x1ba;
pub const KEY_SCHWA: u32 = 0x100018f;
pub const KEY_schwa: u32 = 0x1000259;
pub const KEY_Scircumflex: u32 = 0x2de;
pub const KEY_scircumflex: u32 = 0x2fe;
pub const KEY_script_switch: u32 = 0xff7e;
pub const KEY_Scroll_Lock: u32 = 0xff14;
pub const KEY_seconds: u32 = 0xad7;
pub const KEY_section: u32 = 0xa7;
pub const KEY_Select: u32 = 0xff60;
pub const KEY_semicolon: u32 = 0x3b;
pub const KEY_semivoicedsound: u32 = 0x4df;
pub const KEY_Serbian_DJE: u32 = 0x6b1;
pub const KEY_Serbian_dje: u32 = 0x6a1;
pub const KEY_Serbian_DZE: u32 = 0x6bf;
pub const KEY_Serbian_dze: u32 = 0x6af;
pub const KEY_Serbian_JE: u32 = 0x6b8;
pub const KEY_Serbian_je: u32 = 0x6a8;
pub const KEY_Serbian_LJE: u32 = 0x6b9;
pub const KEY_Serbian_lje: u32 = 0x6a9;
pub const KEY_Serbian_NJE: u32 = 0x6ba;
pub const KEY_Serbian_nje: u32 = 0x6aa;
pub const KEY_Serbian_TSHE: u32 = 0x6bb;
pub const KEY_Serbian_tshe: u32 = 0x6ab;
pub const KEY_seveneighths: u32 = 0xac6;
pub const KEY_sevensubscript: u32 = 0x1002087;
pub const KEY_sevensuperior: u32 = 0x1002077;
pub const KEY_Shift_L: u32 = 0xffe1;
pub const KEY_Shift_Lock: u32 = 0xffe6;
pub const KEY_Shift_R: u32 = 0xffe2;
pub const KEY_signaturemark: u32 = 0xaca;
pub const KEY_signifblank: u32 = 0xaac;
pub const KEY_similarequal: u32 = 0x8c9;
pub const KEY_SingleCandidate: u32 = 0xff3c;
pub const KEY_singlelowquotemark: u32 = 0xafd;
pub const KEY_Sinh_a: u32 = 0x1000d85;
pub const KEY_Sinh_aa: u32 = 0x1000d86;
pub const KEY_Sinh_aa2: u32 = 0x1000dcf;
pub const KEY_Sinh_ae: u32 = 0x1000d87;
pub const KEY_Sinh_ae2: u32 = 0x1000dd0;
pub const KEY_Sinh_aee: u32 = 0x1000d88;
pub const KEY_Sinh_aee2: u32 = 0x1000dd1;
pub const KEY_Sinh_ai: u32 = 0x1000d93;
pub const KEY_Sinh_ai2: u32 = 0x1000ddb;
pub const KEY_Sinh_al: u32 = 0x1000dca;
pub const KEY_Sinh_au: u32 = 0x1000d96;
pub const KEY_Sinh_au2: u32 = 0x1000dde;
pub const KEY_Sinh_ba: u32 = 0x1000db6;
pub const KEY_Sinh_bha: u32 = 0x1000db7;
pub const KEY_Sinh_ca: u32 = 0x1000da0;
pub const KEY_Sinh_cha: u32 = 0x1000da1;
pub const KEY_Sinh_dda: u32 = 0x1000da9;
pub const KEY_Sinh_ddha: u32 = 0x1000daa;
pub const KEY_Sinh_dha: u32 = 0x1000daf;
pub const KEY_Sinh_dhha: u32 = 0x1000db0;
pub const KEY_Sinh_e: u32 = 0x1000d91;
pub const KEY_Sinh_e2: u32 = 0x1000dd9;
pub const KEY_Sinh_ee: u32 = 0x1000d92;
pub const KEY_Sinh_ee2: u32 = 0x1000dda;
pub const KEY_Sinh_fa: u32 = 0x1000dc6;
pub const KEY_Sinh_ga: u32 = 0x1000d9c;
pub const KEY_Sinh_gha: u32 = 0x1000d9d;
pub const KEY_Sinh_h2: u32 = 0x1000d83;
pub const KEY_Sinh_ha: u32 = 0x1000dc4;
pub const KEY_Sinh_i: u32 = 0x1000d89;
pub const KEY_Sinh_i2: u32 = 0x1000dd2;
pub const KEY_Sinh_ii: u32 = 0x1000d8a;
pub const KEY_Sinh_ii2: u32 = 0x1000dd3;
pub const KEY_Sinh_ja: u32 = 0x1000da2;
pub const KEY_Sinh_jha: u32 = 0x1000da3;
pub const KEY_Sinh_jnya: u32 = 0x1000da5;
pub const KEY_Sinh_ka: u32 = 0x1000d9a;
pub const KEY_Sinh_kha: u32 = 0x1000d9b;
pub const KEY_Sinh_kunddaliya: u32 = 0x1000df4;
pub const KEY_Sinh_la: u32 = 0x1000dbd;
pub const KEY_Sinh_lla: u32 = 0x1000dc5;
pub const KEY_Sinh_lu: u32 = 0x1000d8f;
pub const KEY_Sinh_lu2: u32 = 0x1000ddf;
pub const KEY_Sinh_luu: u32 = 0x1000d90;
pub const KEY_Sinh_luu2: u32 = 0x1000df3;
pub const KEY_Sinh_ma: u32 = 0x1000db8;
pub const KEY_Sinh_mba: u32 = 0x1000db9;
pub const KEY_Sinh_na: u32 = 0x1000db1;
pub const KEY_Sinh_ndda: u32 = 0x1000dac;
pub const KEY_Sinh_ndha: u32 = 0x1000db3;
pub const KEY_Sinh_ng: u32 = 0x1000d82;
pub const KEY_Sinh_ng2: u32 = 0x1000d9e;
pub const KEY_Sinh_nga: u32 = 0x1000d9f;
pub const KEY_Sinh_nja: u32 = 0x1000da6;
pub const KEY_Sinh_nna: u32 = 0x1000dab;
pub const KEY_Sinh_nya: u32 = 0x1000da4;
pub const KEY_Sinh_o: u32 = 0x1000d94;
pub const KEY_Sinh_o2: u32 = 0x1000ddc;
pub const KEY_Sinh_oo: u32 = 0x1000d95;
pub const KEY_Sinh_oo2: u32 = 0x1000ddd;
pub const KEY_Sinh_pa: u32 = 0x1000db4;
pub const KEY_Sinh_pha: u32 = 0x1000db5;
pub const KEY_Sinh_ra: u32 = 0x1000dbb;
pub const KEY_Sinh_ri: u32 = 0x1000d8d;
pub const KEY_Sinh_rii: u32 = 0x1000d8e;
pub const KEY_Sinh_ru2: u32 = 0x1000dd8;
pub const KEY_Sinh_ruu2: u32 = 0x1000df2;
pub const KEY_Sinh_sa: u32 = 0x1000dc3;
pub const KEY_Sinh_sha: u32 = 0x1000dc1;
pub const KEY_Sinh_ssha: u32 = 0x1000dc2;
pub const KEY_Sinh_tha: u32 = 0x1000dad;
pub const KEY_Sinh_thha: u32 = 0x1000dae;
pub const KEY_Sinh_tta: u32 = 0x1000da7;
pub const KEY_Sinh_ttha: u32 = 0x1000da8;
pub const KEY_Sinh_u: u32 = 0x1000d8b;
pub const KEY_Sinh_u2: u32 = 0x1000dd4;
pub const KEY_Sinh_uu: u32 = 0x1000d8c;
pub const KEY_Sinh_uu2: u32 = 0x1000dd6;
pub const KEY_Sinh_va: u32 = 0x1000dc0;
pub const KEY_Sinh_ya: u32 = 0x1000dba;
pub const KEY_sixsubscript: u32 = 0x1002086;
pub const KEY_sixsuperior: u32 = 0x1002076;
pub const KEY_slash: u32 = 0x2f;
pub const KEY_SlowKeys_Enable: u32 = 0xfe73;
pub const KEY_soliddiamond: u32 = 0x9e0;
pub const KEY_space: u32 = 0x20;
pub const KEY_squareroot: u32 = 0x100221a;
pub const KEY_ssharp: u32 = 0xdf;
pub const KEY_sterling: u32 = 0xa3;
pub const KEY_StickyKeys_Enable: u32 = 0xfe75;
pub const KEY_stricteq: u32 = 0x1002263;
pub const KEY_SunAgain: u32 = 0xff66;
pub const KEY_SunAltGraph: u32 = 0xff7e;
pub const KEY_SunAudioLowerVolume: u32 = 0x1005ff77;
pub const KEY_SunAudioMute: u32 = 0x1005ff78;
pub const KEY_SunAudioRaiseVolume: u32 = 0x1005ff79;
pub const KEY_SunCompose: u32 = 0xff20;
pub const KEY_SunCopy: u32 = 0x1005ff72;
pub const KEY_SunCut: u32 = 0x1005ff75;
pub const KEY_SunF36: u32 = 0x1005ff10;
pub const KEY_SunF37: u32 = 0x1005ff11;
pub const KEY_SunFA_Acute: u32 = 0x1005ff03;
pub const KEY_SunFA_Cedilla: u32 = 0x1005ff05;
pub const KEY_SunFA_Circum: u32 = 0x1005ff01;
pub const KEY_SunFA_Diaeresis: u32 = 0x1005ff04;
pub const KEY_SunFA_Grave: u32 = 0x1005ff00;
pub const KEY_SunFA_Tilde: u32 = 0x1005ff02;
pub const KEY_SunFind: u32 = 0xff68;
pub const KEY_SunFront: u32 = 0x1005ff71;
pub const KEY_SunOpen: u32 = 0x1005ff73;
pub const KEY_SunPageDown: u32 = 0xff56;
pub const KEY_SunPageUp: u32 = 0xff55;
pub const KEY_SunPaste: u32 = 0x1005ff74;
pub const KEY_SunPowerSwitch: u32 = 0x1005ff76;
pub const KEY_SunPowerSwitchShift: u32 = 0x1005ff7d;
pub const KEY_SunPrint_Screen: u32 = 0xff61;
pub const KEY_SunProps: u32 = 0x1005ff70;
pub const KEY_SunStop: u32 = 0xff69;
pub const KEY_SunSys_Req: u32 = 0x1005ff60;
pub const KEY_SunUndo: u32 = 0xff65;
pub const KEY_SunVideoDegauss: u32 = 0x1005ff7a;
pub const KEY_SunVideoLowerBrightness: u32 = 0x1005ff7b;
pub const KEY_SunVideoRaiseBrightness: u32 = 0x1005ff7c;
pub const KEY_Super_L: u32 = 0xffeb;
pub const KEY_Super_R: u32 = 0xffec;
pub const KEY_Sys_Req: u32 = 0xff15;
pub const KEY_System: u32 = 0x1000ff6d;
pub const KEY_T: u32 = 0x54;
pub const KEY_t: u32 = 0x74;
pub const KEY_Tab: u32 = 0xff09;
pub const KEY_Tabovedot: u32 = 0x1001e6a;
pub const KEY_tabovedot: u32 = 0x1001e6b;
pub const KEY_Tcaron: u32 = 0x1ab;
pub const KEY_tcaron: u32 = 0x1bb;
pub const KEY_Tcedilla: u32 = 0x1de;
pub const KEY_tcedilla: u32 = 0x1fe;
pub const KEY_telephone: u32 = 0xaf9;
pub const KEY_telephonerecorder: u32 = 0xafa;
pub const KEY_Terminate_Server: u32 = 0xfed5;
pub const KEY_Thai_baht: u32 = 0xddf;
pub const KEY_Thai_bobaimai: u32 = 0xdba;
pub const KEY_Thai_chochan: u32 = 0xda8;
pub const KEY_Thai_chochang: u32 = 0xdaa;
pub const KEY_Thai_choching: u32 = 0xda9;
pub const KEY_Thai_chochoe: u32 = 0xdac;
pub const KEY_Thai_dochada: u32 = 0xdae;
pub const KEY_Thai_dodek: u32 = 0xdb4;
pub const KEY_Thai_fofa: u32 = 0xdbd;
pub const KEY_Thai_fofan: u32 = 0xdbf;
pub const KEY_Thai_hohip: u32 = 0xdcb;
pub const KEY_Thai_honokhuk: u32 = 0xdce;
pub const KEY_Thai_khokhai: u32 = 0xda2;
pub const KEY_Thai_khokhon: u32 = 0xda5;
pub const KEY_Thai_khokhuat: u32 = 0xda3;
pub const KEY_Thai_khokhwai: u32 = 0xda4;
pub const KEY_Thai_khorakhang: u32 = 0xda6;
pub const KEY_Thai_kokai: u32 = 0xda1;
pub const KEY_Thai_lakkhangyao: u32 = 0xde5;
pub const KEY_Thai_lekchet: u32 = 0xdf7;
pub const KEY_Thai_lekha: u32 = 0xdf5;
pub const KEY_Thai_lekhok: u32 = 0xdf6;
pub const KEY_Thai_lekkao: u32 = 0xdf9;
pub const KEY_Thai_leknung: u32 = 0xdf1;
pub const KEY_Thai_lekpaet: u32 = 0xdf8;
pub const KEY_Thai_leksam: u32 = 0xdf3;
pub const KEY_Thai_leksi: u32 = 0xdf4;
pub const KEY_Thai_leksong: u32 = 0xdf2;
pub const KEY_Thai_leksun: u32 = 0xdf0;
pub const KEY_Thai_lochula: u32 = 0xdcc;
pub const KEY_Thai_loling: u32 = 0xdc5;
pub const KEY_Thai_lu: u32 = 0xdc6;
pub const KEY_Thai_maichattawa: u32 = 0xdeb;
pub const KEY_Thai_maiek: u32 = 0xde8;
pub const KEY_Thai_maihanakat: u32 = 0xdd1;
pub const KEY_Thai_maihanakat_maitho: u32 = 0xdde;
pub const KEY_Thai_maitaikhu: u32 = 0xde7;
pub const KEY_Thai_maitho: u32 = 0xde9;
pub const KEY_Thai_maitri: u32 = 0xdea;
pub const KEY_Thai_maiyamok: u32 = 0xde6;
pub const KEY_Thai_moma: u32 = 0xdc1;
pub const KEY_Thai_ngongu: u32 = 0xda7;
pub const KEY_Thai_nikhahit: u32 = 0xded;
pub const KEY_Thai_nonen: u32 = 0xdb3;
pub const KEY_Thai_nonu: u32 = 0xdb9;
pub const KEY_Thai_oang: u32 = 0xdcd;
pub const KEY_Thai_paiyannoi: u32 = 0xdcf;
pub const KEY_Thai_phinthu: u32 = 0xdda;
pub const KEY_Thai_phophan: u32 = 0xdbe;
pub const KEY_Thai_phophung: u32 = 0xdbc;
pub const KEY_Thai_phosamphao: u32 = 0xdc0;
pub const KEY_Thai_popla: u32 = 0xdbb;
pub const KEY_Thai_rorua: u32 = 0xdc3;
pub const KEY_Thai_ru: u32 = 0xdc4;
pub const KEY_Thai_saraa: u32 = 0xdd0;
pub const KEY_Thai_saraaa: u32 = 0xdd2;
pub const KEY_Thai_saraae: u32 = 0xde1;
pub const KEY_Thai_saraaimaimalai: u32 = 0xde4;
pub const KEY_Thai_saraaimaimuan: u32 = 0xde3;
pub const KEY_Thai_saraam: u32 = 0xdd3;
pub const KEY_Thai_sarae: u32 = 0xde0;
pub const KEY_Thai_sarai: u32 = 0xdd4;
pub const KEY_Thai_saraii: u32 = 0xdd5;
pub const KEY_Thai_sarao: u32 = 0xde2;
pub const KEY_Thai_sarau: u32 = 0xdd8;
pub const KEY_Thai_saraue: u32 = 0xdd6;
pub const KEY_Thai_sarauee: u32 = 0xdd7;
pub const KEY_Thai_sarauu: u32 = 0xdd9;
pub const KEY_Thai_sorusi: u32 = 0xdc9;
pub const KEY_Thai_sosala: u32 = 0xdc8;
pub const KEY_Thai_soso: u32 = 0xdab;
pub const KEY_Thai_sosua: u32 = 0xdca;
pub const KEY_Thai_thanthakhat: u32 = 0xdec;
pub const KEY_Thai_thonangmontho: u32 = 0xdb1;
pub const KEY_Thai_thophuthao: u32 = 0xdb2;
pub const KEY_Thai_thothahan: u32 = 0xdb7;
pub const KEY_Thai_thothan: u32 = 0xdb0;
pub const KEY_Thai_thothong: u32 = 0xdb8;
pub const KEY_Thai_thothung: u32 = 0xdb6;
pub const KEY_Thai_topatak: u32 = 0xdaf;
pub const KEY_Thai_totao: u32 = 0xdb5;
pub const KEY_Thai_wowaen: u32 = 0xdc7;
pub const KEY_Thai_yoyak: u32 = 0xdc2;
pub const KEY_Thai_yoying: u32 = 0xdad;
pub const KEY_therefore: u32 = 0x8c0;
pub const KEY_thinspace: u32 = 0xaa7;
pub const KEY_THORN: u32 = 0xde;
pub const KEY_Thorn: u32 = 0xde;
pub const KEY_thorn: u32 = 0xfe;
pub const KEY_threeeighths: u32 = 0xac4;
pub const KEY_threefifths: u32 = 0xab4;
pub const KEY_threequarters: u32 = 0xbe;
pub const KEY_threesubscript: u32 = 0x1002083;
pub const KEY_threesuperior: u32 = 0xb3;
pub const KEY_tintegral: u32 = 0x100222d;
pub const KEY_topintegral: u32 = 0x8a4;
pub const KEY_topleftparens: u32 = 0x8ab;
pub const KEY_topleftradical: u32 = 0x8a2;
pub const KEY_topleftsqbracket: u32 = 0x8a7;
pub const KEY_topleftsummation: u32 = 0x8b1;
pub const KEY_toprightparens: u32 = 0x8ad;
pub const KEY_toprightsqbracket: u32 = 0x8a9;
pub const KEY_toprightsummation: u32 = 0x8b5;
pub const KEY_topt: u32 = 0x9f7;
pub const KEY_topvertsummationconnector: u32 = 0x8b3;
pub const KEY_Touroku: u32 = 0xff2b;
pub const KEY_trademark: u32 = 0xac9;
pub const KEY_trademarkincircle: u32 = 0xacb;
pub const KEY_Tslash: u32 = 0x3ac;
pub const KEY_tslash: u32 = 0x3bc;
pub const KEY_twofifths: u32 = 0xab3;
pub const KEY_twosubscript: u32 = 0x1002082;
pub const KEY_twosuperior: u32 = 0xb2;
pub const KEY_twothirds: u32 = 0xab1;
pub const KEY_U: u32 = 0x55;
pub const KEY_u: u32 = 0x75;
pub const KEY_Uacute: u32 = 0xda;
pub const KEY_uacute: u32 = 0xfa;
pub const KEY_Ubelowdot: u32 = 0x1001ee4;
pub const KEY_ubelowdot: u32 = 0x1001ee5;
pub const KEY_Ubreve: u32 = 0x2dd;
pub const KEY_ubreve: u32 = 0x2fd;
pub const KEY_Ucircumflex: u32 = 0xdb;
pub const KEY_ucircumflex: u32 = 0xfb;
pub const KEY_Udiaeresis: u32 = 0xdc;
pub const KEY_udiaeresis: u32 = 0xfc;
pub const KEY_Udoubleacute: u32 = 0x1db;
pub const KEY_udoubleacute: u32 = 0x1fb;
pub const KEY_Ugrave: u32 = 0xd9;
pub const KEY_ugrave: u32 = 0xf9;
pub const KEY_Uhook: u32 = 0x1001ee6;
pub const KEY_uhook: u32 = 0x1001ee7;
pub const KEY_Uhorn: u32 = 0x10001af;
pub const KEY_uhorn: u32 = 0x10001b0;
pub const KEY_Uhornacute: u32 = 0x1001ee8;
pub const KEY_uhornacute: u32 = 0x1001ee9;
pub const KEY_Uhornbelowdot: u32 = 0x1001ef0;
pub const KEY_uhornbelowdot: u32 = 0x1001ef1;
pub const KEY_Uhorngrave: u32 = 0x1001eea;
pub const KEY_uhorngrave: u32 = 0x1001eeb;
pub const KEY_Uhornhook: u32 = 0x1001eec;
pub const KEY_uhornhook: u32 = 0x1001eed;
pub const KEY_Uhorntilde: u32 = 0x1001eee;
pub const KEY_uhorntilde: u32 = 0x1001eef;
pub const KEY_Ukrainian_GHE_WITH_UPTURN: u32 = 0x6bd;
pub const KEY_Ukrainian_ghe_with_upturn: u32 = 0x6ad;
pub const KEY_Ukrainian_I: u32 = 0x6b6;
pub const KEY_Ukrainian_i: u32 = 0x6a6;
pub const KEY_Ukrainian_IE: u32 = 0x6b4;
pub const KEY_Ukrainian_ie: u32 = 0x6a4;
pub const KEY_Ukrainian_YI: u32 = 0x6b7;
pub const KEY_Ukrainian_yi: u32 = 0x6a7;
pub const KEY_Ukranian_I: u32 = 0x6b6;
pub const KEY_Ukranian_i: u32 = 0x6a6;
pub const KEY_Ukranian_JE: u32 = 0x6b4;
pub const KEY_Ukranian_je: u32 = 0x6a4;
pub const KEY_Ukranian_YI: u32 = 0x6b7;
pub const KEY_Ukranian_yi: u32 = 0x6a7;
pub const KEY_Umacron: u32 = 0x3de;
pub const KEY_umacron: u32 = 0x3fe;
pub const KEY_underbar: u32 = 0xbc6;
pub const KEY_underscore: u32 = 0x5f;
pub const KEY_Undo: u32 = 0xff65;
pub const KEY_union: u32 = 0x8dd;
pub const KEY_Uogonek: u32 = 0x3d9;
pub const KEY_uogonek: u32 = 0x3f9;
pub const KEY_Up: u32 = 0xff52;
pub const KEY_uparrow: u32 = 0x8fc;
pub const KEY_upcaret: u32 = 0xba9;
pub const KEY_upleftcorner: u32 = 0x9ec;
pub const KEY_uprightcorner: u32 = 0x9eb;
pub const KEY_upshoe: u32 = 0xbc3;
pub const KEY_upstile: u32 = 0xbd3;
pub const KEY_uptack: u32 = 0xbce;
pub const KEY_Uring: u32 = 0x1d9;
pub const KEY_uring: u32 = 0x1f9;
pub const KEY_User: u32 = 0x1000ff6e;
pub const KEY_Utilde: u32 = 0x3dd;
pub const KEY_utilde: u32 = 0x3fd;
pub const KEY_V: u32 = 0x56;
pub const KEY_v: u32 = 0x76;
pub const KEY_variation: u32 = 0x8c1;
pub const KEY_vertbar: u32 = 0x9f8;
pub const KEY_vertconnector: u32 = 0x8a6;
pub const KEY_voicedsound: u32 = 0x4de;
pub const KEY_VoidSymbol: u32 = 0xffffff;
pub const KEY_vt: u32 = 0x9e9;
pub const KEY_W: u32 = 0x57;
pub const KEY_w: u32 = 0x77;
pub const KEY_Wacute: u32 = 0x1001e82;
pub const KEY_wacute: u32 = 0x1001e83;
pub const KEY_Wcircumflex: u32 = 0x1000174;
pub const KEY_wcircumflex: u32 = 0x1000175;
pub const KEY_Wdiaeresis: u32 = 0x1001e84;
pub const KEY_wdiaeresis: u32 = 0x1001e85;
pub const KEY_Wgrave: u32 = 0x1001e80;
pub const KEY_wgrave: u32 = 0x1001e81;
pub const KEY_WonSign: u32 = 0x10020a9;
pub const KEY_X: u32 = 0x58;
pub const KEY_x: u32 = 0x78;
pub const KEY_Xabovedot: u32 = 0x1001e8a;
pub const KEY_xabovedot: u32 = 0x1001e8b;
pub const KEY_XF8610ChannelsDown: u32 = 0x100811b9;
pub const KEY_XF8610ChannelsUp: u32 = 0x100811b8;
pub const KEY_XF863DMode: u32 = 0x1008126f;
pub const KEY_XF86AddFavorite: u32 = 0x1008ff39;
pub const KEY_XF86Addressbook: u32 = 0x100811ad;
pub const KEY_XF86ALSToggle: u32 = 0x10081230;
pub const KEY_XF86ApplicationLeft: u32 = 0x1008ff50;
pub const KEY_XF86ApplicationRight: u32 = 0x1008ff51;
pub const KEY_XF86AppSelect: u32 = 0x10081244;
pub const KEY_XF86AspectRatio: u32 = 0x10081177;
pub const KEY_XF86Assistant: u32 = 0x10081247;
pub const KEY_XF86AttendantOff: u32 = 0x1008121c;
pub const KEY_XF86AttendantOn: u32 = 0x1008121b;
pub const KEY_XF86AttendantToggle: u32 = 0x1008121d;
pub const KEY_XF86Audio: u32 = 0x10081188;
pub const KEY_XF86AudioCycleTrack: u32 = 0x1008ff9b;
pub const KEY_XF86AudioDesc: u32 = 0x1008126e;
pub const KEY_XF86AudioForward: u32 = 0x1008ff97;
pub const KEY_XF86AudioLowerVolume: u32 = 0x1008ff11;
pub const KEY_XF86AudioMedia: u32 = 0x1008ff32;
pub const KEY_XF86AudioMicMute: u32 = 0x1008ffb2;
pub const KEY_XF86AudioMute: u32 = 0x1008ff12;
pub const KEY_XF86AudioNext: u32 = 0x1008ff17;
pub const KEY_XF86AudioPause: u32 = 0x1008ff31;
pub const KEY_XF86AudioPlay: u32 = 0x1008ff14;
pub const KEY_XF86AudioPreset: u32 = 0x1008ffb6;
pub const KEY_XF86AudioPrev: u32 = 0x1008ff16;
pub const KEY_XF86AudioRaiseVolume: u32 = 0x1008ff13;
pub const KEY_XF86AudioRandomPlay: u32 = 0x1008ff99;
pub const KEY_XF86AudioRecord: u32 = 0x1008ff1c;
pub const KEY_XF86AudioRepeat: u32 = 0x1008ff98;
pub const KEY_XF86AudioRewind: u32 = 0x1008ff3e;
pub const KEY_XF86AudioStop: u32 = 0x1008ff15;
pub const KEY_XF86AutopilotEngageToggle: u32 = 0x1008127d;
pub const KEY_XF86Away: u32 = 0x1008ff8d;
pub const KEY_XF86Back: u32 = 0x1008ff26;
pub const KEY_XF86BackForward: u32 = 0x1008ff3f;
pub const KEY_XF86Battery: u32 = 0x1008ff93;
pub const KEY_XF86Blue: u32 = 0x1008ffa6;
pub const KEY_XF86Bluetooth: u32 = 0x1008ff94;
pub const KEY_XF86Book: u32 = 0x1008ff52;
pub const KEY_XF86Break: u32 = 0x1008119b;
pub const KEY_XF86BrightnessAdjust: u32 = 0x1008ff3b;
pub const KEY_XF86BrightnessAuto: u32 = 0x100810f4;
pub const KEY_XF86BrightnessMax: u32 = 0x10081251;
pub const KEY_XF86BrightnessMin: u32 = 0x10081250;
pub const KEY_XF86Buttonconfig: u32 = 0x10081240;
pub const KEY_XF86Calculater: u32 = 0x1008ff54;
pub const KEY_XF86Calculator: u32 = 0x1008ff1d;
pub const KEY_XF86Calendar: u32 = 0x1008ff20;
pub const KEY_XF86CameraAccessDisable: u32 = 0x1008124c;
pub const KEY_XF86CameraAccessEnable: u32 = 0x1008124b;
pub const KEY_XF86CameraAccessToggle: u32 = 0x1008124d;
pub const KEY_XF86CameraDown: u32 = 0x10081218;
pub const KEY_XF86CameraFocus: u32 = 0x10081210;
pub const KEY_XF86CameraLeft: u32 = 0x10081219;
pub const KEY_XF86CameraRight: u32 = 0x1008121a;
pub const KEY_XF86CameraUp: u32 = 0x10081217;
pub const KEY_XF86CameraZoomIn: u32 = 0x10081215;
pub const KEY_XF86CameraZoomOut: u32 = 0x10081216;
pub const KEY_XF86CD: u32 = 0x1008ff53;
pub const KEY_XF86ChannelDown: u32 = 0x10081193;
pub const KEY_XF86ChannelUp: u32 = 0x10081192;
pub const KEY_XF86Clear: u32 = 0x1008ff55;
pub const KEY_XF86ClearGrab: u32 = 0x1008fe21;
pub const KEY_XF86ClearvuSonar: u32 = 0x10081286;
pub const KEY_XF86Close: u32 = 0x1008ff56;
pub const KEY_XF86Community: u32 = 0x1008ff3d;
pub const KEY_XF86ContextMenu: u32 = 0x100811b6;
pub const KEY_XF86ContrastAdjust: u32 = 0x1008ff22;
pub const KEY_XF86ControlPanel: u32 = 0x10081243;
pub const KEY_XF86Copy: u32 = 0x1008ff57;
pub const KEY_XF86Cut: u32 = 0x1008ff58;
pub const KEY_XF86CycleAngle: u32 = 0x1008ff9c;
pub const KEY_XF86Data: u32 = 0x10081277;
pub const KEY_XF86Database: u32 = 0x100811aa;
pub const KEY_XF86Dictate: u32 = 0x1008124a;
pub const KEY_XF86Display: u32 = 0x1008ff59;
pub const KEY_XF86DisplayOff: u32 = 0x100810f5;
pub const KEY_XF86DisplayToggle: u32 = 0x100811af;
pub const KEY_XF86Documents: u32 = 0x1008ff5b;
pub const KEY_XF86DOS: u32 = 0x1008ff5a;
pub const KEY_XF86DualRangeRadar: u32 = 0x10081283;
pub const KEY_XF86DVD: u32 = 0x10081185;
pub const KEY_XF86Editor: u32 = 0x100811a6;
pub const KEY_XF86Eject: u32 = 0x1008ff2c;
pub const KEY_XF86EmojiPicker: u32 = 0x10081249;
pub const KEY_XF86Excel: u32 = 0x1008ff5c;
pub const KEY_XF86Explorer: u32 = 0x1008ff5d;
pub const KEY_XF86FastReverse: u32 = 0x10081275;
pub const KEY_XF86Favorites: u32 = 0x1008ff30;
pub const KEY_XF86Finance: u32 = 0x1008ff3c;
pub const KEY_XF86FishingChart: u32 = 0x10081281;
pub const KEY_XF86Fn: u32 = 0x100811d0;
pub const KEY_XF86Fn_Esc: u32 = 0x100811d1;
pub const KEY_XF86FnRightShift: u32 = 0x100811e5;
pub const KEY_XF86Forward: u32 = 0x1008ff27;
pub const KEY_XF86FrameBack: u32 = 0x1008ff9d;
pub const KEY_XF86FrameForward: u32 = 0x1008ff9e;
pub const KEY_XF86FullScreen: u32 = 0x1008ffb8;
pub const KEY_XF86Game: u32 = 0x1008ff5e;
pub const KEY_XF86Go: u32 = 0x1008ff5f;
pub const KEY_XF86GraphicsEditor: u32 = 0x100811a8;
pub const KEY_XF86Green: u32 = 0x1008ffa4;
pub const KEY_XF86HangupPhone: u32 = 0x100811be;
pub const KEY_XF86Hibernate: u32 = 0x1008ffa8;
pub const KEY_XF86History: u32 = 0x1008ff37;
pub const KEY_XF86HomePage: u32 = 0x1008ff18;
pub const KEY_XF86HotLinks: u32 = 0x1008ff3a;
pub const KEY_XF86Images: u32 = 0x100811ba;
pub const KEY_XF86Info: u32 = 0x10081166;
pub const KEY_XF86iTouch: u32 = 0x1008ff60;
pub const KEY_XF86Journal: u32 = 0x10081242;
pub const KEY_XF86KbdBrightnessDown: u32 = 0x1008ff06;
pub const KEY_XF86KbdBrightnessUp: u32 = 0x1008ff05;
pub const KEY_XF86KbdInputAssistAccept: u32 = 0x10081264;
pub const KEY_XF86KbdInputAssistCancel: u32 = 0x10081265;
pub const KEY_XF86KbdInputAssistNext: u32 = 0x10081261;
pub const KEY_XF86KbdInputAssistNextgroup: u32 = 0x10081263;
pub const KEY_XF86KbdInputAssistPrev: u32 = 0x10081260;
pub const KEY_XF86KbdInputAssistPrevgroup: u32 = 0x10081262;
pub const KEY_XF86KbdLcdMenu1: u32 = 0x100812b8;
pub const KEY_XF86KbdLcdMenu2: u32 = 0x100812b9;
pub const KEY_XF86KbdLcdMenu3: u32 = 0x100812ba;
pub const KEY_XF86KbdLcdMenu4: u32 = 0x100812bb;
pub const KEY_XF86KbdLcdMenu5: u32 = 0x100812bc;
pub const KEY_XF86KbdLightOnOff: u32 = 0x1008ff04;
pub const KEY_XF86Keyboard: u32 = 0x1008ffb3;
pub const KEY_XF86Launch0: u32 = 0x1008ff40;
pub const KEY_XF86Launch1: u32 = 0x1008ff41;
pub const KEY_XF86Launch2: u32 = 0x1008ff42;
pub const KEY_XF86Launch3: u32 = 0x1008ff43;
pub const KEY_XF86Launch4: u32 = 0x1008ff44;
pub const KEY_XF86Launch5: u32 = 0x1008ff45;
pub const KEY_XF86Launch6: u32 = 0x1008ff46;
pub const KEY_XF86Launch7: u32 = 0x1008ff47;
pub const KEY_XF86Launch8: u32 = 0x1008ff48;
pub const KEY_XF86Launch9: u32 = 0x1008ff49;
pub const KEY_XF86LaunchA: u32 = 0x1008ff4a;
pub const KEY_XF86LaunchB: u32 = 0x1008ff4b;
pub const KEY_XF86LaunchC: u32 = 0x1008ff4c;
pub const KEY_XF86LaunchD: u32 = 0x1008ff4d;
pub const KEY_XF86LaunchE: u32 = 0x1008ff4e;
pub const KEY_XF86LaunchF: u32 = 0x1008ff4f;
pub const KEY_XF86LeftDown: u32 = 0x10081269;
pub const KEY_XF86LeftUp: u32 = 0x10081268;
pub const KEY_XF86LightBulb: u32 = 0x1008ff35;
pub const KEY_XF86LightsToggle: u32 = 0x1008121e;
pub const KEY_XF86LogGrabInfo: u32 = 0x1008fe25;
pub const KEY_XF86LogOff: u32 = 0x1008ff61;
pub const KEY_XF86LogWindowTree: u32 = 0x1008fe24;
pub const KEY_XF86Macro1: u32 = 0x10081290;
pub const KEY_XF86Macro10: u32 = 0x10081299;
pub const KEY_XF86Macro11: u32 = 0x1008129a;
pub const KEY_XF86Macro12: u32 = 0x1008129b;
pub const KEY_XF86Macro13: u32 = 0x1008129c;
pub const KEY_XF86Macro14: u32 = 0x1008129d;
pub const KEY_XF86Macro15: u32 = 0x1008129e;
pub const KEY_XF86Macro16: u32 = 0x1008129f;
pub const KEY_XF86Macro17: u32 = 0x100812a0;
pub const KEY_XF86Macro18: u32 = 0x100812a1;
pub const KEY_XF86Macro19: u32 = 0x100812a2;
pub const KEY_XF86Macro2: u32 = 0x10081291;
pub const KEY_XF86Macro20: u32 = 0x100812a3;
pub const KEY_XF86Macro21: u32 = 0x100812a4;
pub const KEY_XF86Macro22: u32 = 0x100812a5;
pub const KEY_XF86Macro23: u32 = 0x100812a6;
pub const KEY_XF86Macro24: u32 = 0x100812a7;
pub const KEY_XF86Macro25: u32 = 0x100812a8;
pub const KEY_XF86Macro26: u32 = 0x100812a9;
pub const KEY_XF86Macro27: u32 = 0x100812aa;
pub const KEY_XF86Macro28: u32 = 0x100812ab;
pub const KEY_XF86Macro29: u32 = 0x100812ac;
pub const KEY_XF86Macro3: u32 = 0x10081292;
pub const KEY_XF86Macro30: u32 = 0x100812ad;
pub const KEY_XF86Macro4: u32 = 0x10081293;
pub const KEY_XF86Macro5: u32 = 0x10081294;
pub const KEY_XF86Macro6: u32 = 0x10081295;
pub const KEY_XF86Macro7: u32 = 0x10081296;
pub const KEY_XF86Macro8: u32 = 0x10081297;
pub const KEY_XF86Macro9: u32 = 0x10081298;
pub const KEY_XF86MacroPreset1: u32 = 0x100812b3;
pub const KEY_XF86MacroPreset2: u32 = 0x100812b4;
pub const KEY_XF86MacroPreset3: u32 = 0x100812b5;
pub const KEY_XF86MacroPresetCycle: u32 = 0x100812b2;
pub const KEY_XF86MacroRecordStart: u32 = 0x100812b0;
pub const KEY_XF86MacroRecordStop: u32 = 0x100812b1;
pub const KEY_XF86Mail: u32 = 0x1008ff19;
pub const KEY_XF86MailForward: u32 = 0x1008ff90;
pub const KEY_XF86Market: u32 = 0x1008ff62;
pub const KEY_XF86MarkWaypoint: u32 = 0x1008127e;
pub const KEY_XF86MediaRepeat: u32 = 0x100811b7;
pub const KEY_XF86MediaTopMenu: u32 = 0x1008126b;
pub const KEY_XF86Meeting: u32 = 0x1008ff63;
pub const KEY_XF86Memo: u32 = 0x1008ff1e;
pub const KEY_XF86MenuKB: u32 = 0x1008ff65;
pub const KEY_XF86MenuPB: u32 = 0x1008ff66;
pub const KEY_XF86Messenger: u32 = 0x1008ff8e;
pub const KEY_XF86ModeLock: u32 = 0x1008ff01;
pub const KEY_XF86MonBrightnessCycle: u32 = 0x1008ff07;
pub const KEY_XF86MonBrightnessDown: u32 = 0x1008ff03;
pub const KEY_XF86MonBrightnessUp: u32 = 0x1008ff02;
pub const KEY_XF86Music: u32 = 0x1008ff92;
pub const KEY_XF86MyComputer: u32 = 0x1008ff33;
pub const KEY_XF86MySites: u32 = 0x1008ff67;
pub const KEY_XF86NavChart: u32 = 0x10081280;
pub const KEY_XF86NavInfo: u32 = 0x10081288;
pub const KEY_XF86New: u32 = 0x1008ff68;
pub const KEY_XF86News: u32 = 0x1008ff69;
pub const KEY_XF86Next_VMode: u32 = 0x1008fe22;
pub const KEY_XF86NextElement: u32 = 0x1008127b;
pub const KEY_XF86NextFavorite: u32 = 0x10081270;
pub const KEY_XF86NotificationCenter: u32 = 0x100811bc;
pub const KEY_XF86Numeric0: u32 = 0x10081200;
pub const KEY_XF86Numeric1: u32 = 0x10081201;
pub const KEY_XF86Numeric11: u32 = 0x1008126c;
pub const KEY_XF86Numeric12: u32 = 0x1008126d;
pub const KEY_XF86Numeric2: u32 = 0x10081202;
pub const KEY_XF86Numeric3: u32 = 0x10081203;
pub const KEY_XF86Numeric4: u32 = 0x10081204;
pub const KEY_XF86Numeric5: u32 = 0x10081205;
pub const KEY_XF86Numeric6: u32 = 0x10081206;
pub const KEY_XF86Numeric7: u32 = 0x10081207;
pub const KEY_XF86Numeric8: u32 = 0x10081208;
pub const KEY_XF86Numeric9: u32 = 0x10081209;
pub const KEY_XF86NumericA: u32 = 0x1008120c;
pub const KEY_XF86NumericB: u32 = 0x1008120d;
pub const KEY_XF86NumericC: u32 = 0x1008120e;
pub const KEY_XF86NumericD: u32 = 0x1008120f;
pub const KEY_XF86NumericPound: u32 = 0x1008120b;
pub const KEY_XF86NumericStar: u32 = 0x1008120a;
pub const KEY_XF86OfficeHome: u32 = 0x1008ff6a;
pub const KEY_XF86OnScreenKeyboard: u32 = 0x10081278;
pub const KEY_XF86Open: u32 = 0x1008ff6b;
pub const KEY_XF86OpenURL: u32 = 0x1008ff38;
pub const KEY_XF86Option: u32 = 0x1008ff6c;
pub const KEY_XF86Paste: u32 = 0x1008ff6d;
pub const KEY_XF86PauseRecord: u32 = 0x10081272;
pub const KEY_XF86Phone: u32 = 0x1008ff6e;
pub const KEY_XF86PickupPhone: u32 = 0x100811bd;
pub const KEY_XF86Pictures: u32 = 0x1008ff91;
pub const KEY_XF86PowerDown: u32 = 0x1008ff21;
pub const KEY_XF86PowerOff: u32 = 0x1008ff2a;
pub const KEY_XF86Presentation: u32 = 0x100811a9;
pub const KEY_XF86Prev_VMode: u32 = 0x1008fe23;
pub const KEY_XF86PreviousElement: u32 = 0x1008127c;
pub const KEY_XF86PrivacyScreenToggle: u32 = 0x10081279;
pub const KEY_XF86Q: u32 = 0x1008ff70;
pub const KEY_XF86RadarOverlay: u32 = 0x10081284;
pub const KEY_XF86Red: u32 = 0x1008ffa3;
pub const KEY_XF86Refresh: u32 = 0x1008ff29;
pub const KEY_XF86Reload: u32 = 0x1008ff73;
pub const KEY_XF86Reply: u32 = 0x1008ff72;
pub const KEY_XF86RFKill: u32 = 0x1008ffb5;
pub const KEY_XF86RightDown: u32 = 0x10081267;
pub const KEY_XF86RightUp: u32 = 0x10081266;
pub const KEY_XF86RockerDown: u32 = 0x1008ff24;
pub const KEY_XF86RockerEnter: u32 = 0x1008ff25;
pub const KEY_XF86RockerUp: u32 = 0x1008ff23;
pub const KEY_XF86RootMenu: u32 = 0x1008126a;
pub const KEY_XF86RotateWindows: u32 = 0x1008ff74;
pub const KEY_XF86RotationKB: u32 = 0x1008ff76;
pub const KEY_XF86RotationLockToggle: u32 = 0x1008ffb7;
pub const KEY_XF86RotationPB: u32 = 0x1008ff75;
pub const KEY_XF86Save: u32 = 0x1008ff77;
pub const KEY_XF86ScreenSaver: u32 = 0x1008ff2d;
pub const KEY_XF86Screensaver: u32 = 0x10081245;
pub const KEY_XF86ScrollClick: u32 = 0x1008ff7a;
pub const KEY_XF86ScrollDown: u32 = 0x1008ff79;
pub const KEY_XF86ScrollUp: u32 = 0x1008ff78;
pub const KEY_XF86Search: u32 = 0x1008ff1b;
pub const KEY_XF86Select: u32 = 0x1008ffa0;
pub const KEY_XF86SelectiveScreenshot: u32 = 0x1008127a;
pub const KEY_XF86Send: u32 = 0x1008ff7b;
pub const KEY_XF86Shop: u32 = 0x1008ff36;
pub const KEY_XF86SidevuSonar: u32 = 0x10081287;
pub const KEY_XF86SingleRangeRadar: u32 = 0x10081282;
pub const KEY_XF86Sleep: u32 = 0x1008ff2f;
pub const KEY_XF86SlowReverse: u32 = 0x10081276;
pub const KEY_XF86Sos: u32 = 0x1008127f;
pub const KEY_XF86Spell: u32 = 0x1008ff7c;
pub const KEY_XF86SpellCheck: u32 = 0x100811b0;
pub const KEY_XF86SplitScreen: u32 = 0x1008ff7d;
pub const KEY_XF86Standby: u32 = 0x1008ff10;
pub const KEY_XF86Start: u32 = 0x1008ff1a;
pub const KEY_XF86Stop: u32 = 0x1008ff28;
pub const KEY_XF86StopRecord: u32 = 0x10081271;
pub const KEY_XF86Subtitle: u32 = 0x1008ff9a;
pub const KEY_XF86Support: u32 = 0x1008ff7e;
pub const KEY_XF86Suspend: u32 = 0x1008ffa7;
pub const KEY_XF86Switch_VT_1: u32 = 0x1008fe01;
pub const KEY_XF86Switch_VT_10: u32 = 0x1008fe0a;
pub const KEY_XF86Switch_VT_11: u32 = 0x1008fe0b;
pub const KEY_XF86Switch_VT_12: u32 = 0x1008fe0c;
pub const KEY_XF86Switch_VT_2: u32 = 0x1008fe02;
pub const KEY_XF86Switch_VT_3: u32 = 0x1008fe03;
pub const KEY_XF86Switch_VT_4: u32 = 0x1008fe04;
pub const KEY_XF86Switch_VT_5: u32 = 0x1008fe05;
pub const KEY_XF86Switch_VT_6: u32 = 0x1008fe06;
pub const KEY_XF86Switch_VT_7: u32 = 0x1008fe07;
pub const KEY_XF86Switch_VT_8: u32 = 0x1008fe08;
pub const KEY_XF86Switch_VT_9: u32 = 0x1008fe09;
pub const KEY_XF86Taskmanager: u32 = 0x10081241;
pub const KEY_XF86TaskPane: u32 = 0x1008ff7f;
pub const KEY_XF86Terminal: u32 = 0x1008ff80;
pub const KEY_XF86Time: u32 = 0x1008ff9f;
pub const KEY_XF86ToDoList: u32 = 0x1008ff1f;
pub const KEY_XF86Tools: u32 = 0x1008ff81;
pub const KEY_XF86TopMenu: u32 = 0x1008ffa2;
pub const KEY_XF86TouchpadOff: u32 = 0x1008ffb1;
pub const KEY_XF86TouchpadOn: u32 = 0x1008ffb0;
pub const KEY_XF86TouchpadToggle: u32 = 0x1008ffa9;
pub const KEY_XF86TraditionalSonar: u32 = 0x10081285;
pub const KEY_XF86Travel: u32 = 0x1008ff82;
pub const KEY_XF86Ungrab: u32 = 0x1008fe20;
pub const KEY_XF86Unmute: u32 = 0x10081274;
pub const KEY_XF86User1KB: u32 = 0x1008ff85;
pub const KEY_XF86User2KB: u32 = 0x1008ff86;
pub const KEY_XF86UserPB: u32 = 0x1008ff84;
pub const KEY_XF86UWB: u32 = 0x1008ff96;
pub const KEY_XF86VendorHome: u32 = 0x1008ff34;
pub const KEY_XF86Video: u32 = 0x1008ff87;
pub const KEY_XF86VideoPhone: u32 = 0x100811a0;
pub const KEY_XF86View: u32 = 0x1008ffa1;
pub const KEY_XF86VOD: u32 = 0x10081273;
pub const KEY_XF86VoiceCommand: u32 = 0x10081246;
pub const KEY_XF86Voicemail: u32 = 0x100811ac;
pub const KEY_XF86WakeUp: u32 = 0x1008ff2b;
pub const KEY_XF86WebCam: u32 = 0x1008ff8f;
pub const KEY_XF86WheelButton: u32 = 0x1008ff88;
pub const KEY_XF86WLAN: u32 = 0x1008ff95;
pub const KEY_XF86Word: u32 = 0x1008ff89;
pub const KEY_XF86WPSButton: u32 = 0x10081211;
pub const KEY_XF86WWAN: u32 = 0x1008ffb4;
pub const KEY_XF86WWW: u32 = 0x1008ff2e;
pub const KEY_XF86Xfer: u32 = 0x1008ff8a;
pub const KEY_XF86Yellow: u32 = 0x1008ffa5;
pub const KEY_XF86ZoomIn: u32 = 0x1008ff8b;
pub const KEY_XF86ZoomOut: u32 = 0x1008ff8c;
pub const KEY_XF86ZoomReset: u32 = 0x100811a4;
pub const KEY_Y: u32 = 0x59;
pub const KEY_y: u32 = 0x79;
pub const KEY_Yacute: u32 = 0xdd;
pub const KEY_yacute: u32 = 0xfd;
pub const KEY_Ybelowdot: u32 = 0x1001ef4;
pub const KEY_ybelowdot: u32 = 0x1001ef5;
pub const KEY_Ycircumflex: u32 = 0x1000176;
pub const KEY_ycircumflex: u32 = 0x1000177;
pub const KEY_Ydiaeresis: u32 = 0x13be;
pub const KEY_ydiaeresis: u32 = 0xff;
pub const KEY_yen: u32 = 0xa5;
pub const KEY_Ygrave: u32 = 0x1001ef2;
pub const KEY_ygrave: u32 = 0x1001ef3;
pub const KEY_Yhook: u32 = 0x1001ef6;
pub const KEY_yhook: u32 = 0x1001ef7;
pub const KEY_Ytilde: u32 = 0x1001ef8;
pub const KEY_ytilde: u32 = 0x1001ef9;
pub const KEY_Z: u32 = 0x5a;
pub const KEY_z: u32 = 0x7a;
pub const KEY_Zabovedot: u32 = 0x1af;
pub const KEY_zabovedot: u32 = 0x1bf;
pub const KEY_Zacute: u32 = 0x1ac;
pub const KEY_zacute: u32 = 0x1bc;
pub const KEY_Zcaron: u32 = 0x1ae;
pub const KEY_zcaron: u32 = 0x1be;
pub const KEY_Zen_Koho: u32 = 0xff3d;
pub const KEY_Zenkaku: u32 = 0xff28;
pub const KEY_Zenkaku_Hankaku: u32 = 0xff2a;
pub const KEY_zerosubscript: u32 = 0x1002080;
pub const KEY_zerosuperior: u32 = 0x1002070;
pub const KEY_Zstroke: u32 = 0x10001b5;
pub const KEY_zstroke: u32 = 0x10001b6;

/// Every keysym name with its value, in libxkbcommon's `name_to_keysym`
/// order: by ASCII case-folded name, then by name.
pub(in crate::platform) static NAME_TO_KEYSYM: [(&str, u32); 2576] = [
    ("0", KEY_0),
    ("1", KEY_1),
    ("2", KEY_2),
    ("3", KEY_3),
    ("3270_AltCursor", KEY_3270_AltCursor),
    ("3270_Attn", KEY_3270_Attn),
    ("3270_BackTab", KEY_3270_BackTab),
    ("3270_ChangeScreen", KEY_3270_ChangeScreen),
    ("3270_Copy", KEY_3270_Copy),
    ("3270_CursorBlink", KEY_3270_CursorBlink),
    ("3270_CursorSelect", KEY_3270_CursorSelect),
    ("3270_DeleteWord", KEY_3270_DeleteWord),
    ("3270_Duplicate", KEY_3270_Duplicate),
    ("3270_Enter", KEY_3270_Enter),
    ("3270_EraseEOF", KEY_3270_EraseEOF),
    ("3270_EraseInput", KEY_3270_EraseInput),
    ("3270_ExSelect", KEY_3270_ExSelect),
    ("3270_FieldMark", KEY_3270_FieldMark),
    ("3270_Ident", KEY_3270_Ident),
    ("3270_Jump", KEY_3270_Jump),
    ("3270_KeyClick", KEY_3270_KeyClick),
    ("3270_Left2", KEY_3270_Left2),
    ("3270_PA1", KEY_3270_PA1),
    ("3270_PA2", KEY_3270_PA2),
    ("3270_PA3", KEY_3270_PA3),
    ("3270_Play", KEY_3270_Play),
    ("3270_PrintScreen", KEY_3270_PrintScreen),
    ("3270_Quit", KEY_3270_Quit),
    ("3270_Record", KEY_3270_Record),
    ("3270_Reset", KEY_3270_Reset),
    ("3270_Right2", KEY_3270_Right2),
    ("3270_Rule", KEY_3270_Rule),
    ("3270_Setup", KEY_3270_Setup),
    ("3270_Test", KEY_3270_Test),
    ("4", KEY_4),
    ("5", KEY_5),
    ("6", KEY_6),
    ("7", KEY_7),
    ("8", KEY_8),
    ("9", KEY_9),
    ("A", KEY_A),
    ("a", KEY_a),
    ("Aacute", KEY_Aacute),
    ("aacute", KEY_aacute),
    ("Abelowdot", KEY_Abelowdot),
    ("abelowdot", KEY_abelowdot),
    ("abovedot", KEY_abovedot),
    ("Abreve", KEY_Abreve),
    ("abreve", KEY_abreve),
    ("Abreveacute", KEY_Abreveacute),
    ("abreveacute", KEY_abreveacute),
    ("Abrevebelowdot", KEY_Abrevebelowdot),
    ("abrevebelowdot", KEY_abrevebelowdot),
    ("Abrevegrave", KEY_Abrevegrave),
    ("abrevegrave", KEY_abrevegrave),
    ("Abrevehook", KEY_Abrevehook),
    ("abrevehook", KEY_abrevehook),
    ("Abrevetilde", KEY_Abrevetilde),
    ("abrevetilde", KEY_abrevetilde),
    ("AccessX_Enable", KEY_AccessX_Enable),
    ("AccessX_Feedback_Enable", KEY_AccessX_Feedback_Enable),
    ("Acircumflex", KEY_Acircumflex),
    ("acircumflex", KEY_acircumflex),
    ("Acircumflexacute", KEY_Acircumflexacute),
    ("acircumflexacute", KEY_acircumflexacute),
    ("Acircumflexbelowdot", KEY_Acircumflexbelowdot),
    ("acircumflexbelowdot", KEY_acircumflexbelowdot),
    ("Acircumflexgrave", KEY_Acircumflexgrave),
    ("acircumflexgrave", KEY_acircumflexgrave),
    ("Acircumflexhook", KEY_Acircumflexhook),
    ("acircumflexhook", KEY_acircumflexhook),
    ("Acircumflextilde", KEY_Acircumflextilde),
    ("acircumflextilde", KEY_acircumflextilde),
    ("acute", KEY_acute),
    ("Adiaeresis", KEY_Adiaeresis),
    ("adiaeresis", KEY_adiaeresis),
    ("AE", KEY_AE),
    ("ae", KEY_ae),
    ("Agrave", KEY_Agrave),
    ("agrave", KEY_agrave),
    ("Ahook", KEY_Ahook),
    ("ahook", KEY_ahook),
    ("Alt_L", KEY_Alt_L),
    ("Alt_R", KEY_Alt_R),
    ("Amacron", KEY_Amacron),
    ("amacron", KEY_amacron),
    ("ampersand", KEY_ampersand),
    ("Aogonek", KEY_Aogonek),
    ("aogonek", KEY_aogonek),
    ("apostrophe", KEY_apostrophe),
    ("approxeq", KEY_approxeq),
    ("approximate", KEY_approximate),
    ("Arabic_0", KEY_Arabic_0),
    ("Arabic_1", KEY_Arabic_1),
    ("Arabic_2", KEY_Arabic_2),
    ("Arabic_3", KEY_Arabic_3),
    ("Arabic_4", KEY_Arabic_4),
    ("Arabic_5", KEY_Arabic_5),
    ("Arabic_6", KEY_Arabic_6),
    ("Arabic_7", KEY_Arabic_7),
    ("Arabic_8", KEY_Arabic_8),
    ("Arabic_9", KEY_Arabic_9),
    ("Arabic_ain", KEY_Arabic_ain),
    ("Arabic_alef", KEY_Arabic_alef),
    ("Arabic_alefmaksura", KEY_Arabic_alefmaksura),
    ("Arabic_beh", KEY_Arabic_beh),
    ("Arabic_comma", KEY_Arabic_comma),
    ("Arabic_dad", KEY_Arabic_dad),
    ("Arabic_dal", KEY_Arabic_dal),
    ("Arabic_damma", KEY_Arabic_damma),
    ("Arabic_dammatan", KEY_Arabic_dammatan),
    ("Arabic_ddal", KEY_Arabic_ddal),
    ("Arabic_farsi_yeh", KEY_Arabic_farsi_yeh),
    ("Arabic_fatha", KEY_Arabic_fatha),
    ("Arabic_fathatan", KEY_Arabic_fathatan),
    ("Arabic_feh", KEY_Arabic_feh),
    ("Arabic_fullstop", KEY_Arabic_fullstop),
    ("Arabic_gaf", KEY_Arabic_gaf),
    ("Arabic_ghain", KEY_Arabic_ghain),
    ("Arabic_ha", KEY_Arabic_ha),
    ("Arabic_hah", KEY_Arabic_hah),
    ("Arabic_hamza", KEY_Arabic_hamza),
    ("Arabic_hamza_above", KEY_Arabic_hamza_above),
    ("Arabic_hamza_below", KEY_Arabic_hamza_below),
    ("Arabic_hamzaonalef", KEY_Arabic_hamzaonalef),
    ("Arabic_hamzaonwaw", KEY_Arabic_hamzaonwaw),
    ("Arabic_hamzaonyeh", KEY_Arabic_hamzaonyeh),
    ("Arabic_hamzaunderalef", KEY_Arabic_hamzaunderalef),
    ("Arabic_heh", KEY_Arabic_heh),
    ("Arabic_heh_doachashmee", KEY_Arabic_heh_doachashmee),
    ("Arabic_heh_goal", KEY_Arabic_heh_goal),
    ("Arabic_jeem", KEY_Arabic_jeem),
    ("Arabic_jeh", KEY_Arabic_jeh),
    ("Arabic_kaf", KEY_Arabic_kaf),
    ("Arabic_kasra", KEY_Arabic_kasra),
    ("Arabic_kasratan", KEY_Arabic_kasratan),
    ("Arabic_keheh", KEY_Arabic_keheh),
    ("Arabic_khah", KEY_Arabic_khah),
    ("Arabic_lam", KEY_Arabic_lam),
    ("Arabic_madda_above", KEY_Arabic_madda_above),
    ("Arabic_maddaonalef", KEY_Arabic_maddaonalef),
    ("Arabic_meem", KEY_Arabic_meem),
    ("Arabic_noon", KEY_Arabic_noon),
    ("Arabic_noon_ghunna", KEY_Arabic_noon_ghunna),
    ("Arabic_peh", KEY_Arabic_peh),
    ("Arabic_percent", KEY_Arabic_percent),
    ("Arabic_qaf", KEY_Arabic_qaf),
    ("Arabic_question_mark", KEY_Arabic_question_mark),
    ("Arabic_ra", KEY_Arabic_ra),
    ("Arabic_rreh", KEY_Arabic_rreh),
    ("Arabic_sad", KEY_Arabic_sad),
    ("Arabic_seen", KEY_Arabic_seen),
    ("Arabic_semicolon", KEY_Arabic_semicolon),
    ("Arabic_shadda", KEY_Arabic_shadda),
    ("Arabic_sheen", KEY_Arabic_sheen),
    ("Arabic_sukun", KEY_Arabic_sukun),
    ("Arabic_superscript_alef", KEY_Arabic_superscript_alef),
    ("Arabic_switch", KEY_Arabic_switch),
    ("Arabic_tah", KEY_Arabic_tah),
    ("Arabic_tatweel", KEY_Arabic_tatweel),
    ("Arabic_tcheh", KEY_Arabic_tcheh),
    ("Arabic_teh", KEY_Arabic_teh),
    ("Arabic_tehmarbuta", KEY_Arabic_tehmarbuta),
    ("Arabic_thal", KEY_Arabic_thal),
    ("Arabic_theh", KEY_Arabic_theh),
    ("Arabic_tteh", KEY_Arabic_tteh),
    ("Arabic_veh", KEY_Arabic_veh),
    ("Arabic_waw", KEY_Arabic_waw),
    ("Arabic_yeh", KEY_Arabic_yeh),
    ("Arabic_yeh_baree", KEY_Arabic_yeh_baree),
    ("Arabic_zah", KEY_Arabic_zah),
    ("Arabic_zain", KEY_Arabic_zain),
    ("Aring", KEY_Aring),
    ("aring", KEY_aring),
    ("Armenian_accent", KEY_Armenian_accent),
    ("Armenian_amanak", KEY_Armenian_amanak),
    ("Armenian_apostrophe", KEY_Armenian_apostrophe),
    ("Armenian_AT", KEY_Armenian_AT),
    ("Armenian_at", KEY_Armenian_at),
    ("Armenian_AYB", KEY_Armenian_AYB),
    ("Armenian_ayb", KEY_Armenian_ayb),
    ("Armenian_BEN", KEY_Armenian_BEN),
    ("Armenian_ben", KEY_Armenian_ben),
    ("Armenian_but", KEY_Armenian_but),
    ("Armenian_CHA", KEY_Armenian_CHA),
    ("Armenian_cha", KEY_Armenian_cha),
    ("Armenian_DA", KEY_Armenian_DA),
    ("Armenian_da", KEY_Armenian_da),
    ("Armenian_DZA", KEY_Armenian_DZA),
    ("Armenian_dza", KEY_Armenian_dza),
    ("Armenian_E", KEY_Armenian_E),
    ("Armenian_e", KEY_Armenian_e),
    ("Armenian_exclam", KEY_Armenian_exclam),
    ("Armenian_FE", KEY_Armenian_FE),
    ("Armenian_fe", KEY_Armenian_fe),
    ("Armenian_full_stop", KEY_Armenian_full_stop),
    ("Armenian_GHAT", KEY_Armenian_GHAT),
    ("Armenian_ghat", KEY_Armenian_ghat),
    ("Armenian_GIM", KEY_Armenian_GIM),
    ("Armenian_gim", KEY_Armenian_gim),
    ("Armenian_HI", KEY_Armenian_HI),
    ("Armenian_hi", KEY_Armenian_hi),
    ("Armenian_HO", KEY_Armenian_HO),
    ("Armenian_ho", KEY_Armenian_ho),
    ("Armenian_hyphen", KEY_Armenian_hyphen),
    ("Armenian_INI", KEY_Armenian_INI),
    ("Armenian_ini", KEY_Armenian_ini),
    ("Armenian_JE", KEY_Armenian_JE),
    ("Armenian_je", KEY_Armenian_je),
    ("Armenian_KE", KEY_Armenian_KE),
    ("Armenian_ke", KEY_Armenian_ke),
    ("Armenian_KEN", KEY_Armenian_KEN),
    ("Armenian_ken", KEY_Armenian_ken),
    ("Armenian_KHE", KEY_Armenian_KHE),
    ("Armenian_khe", KEY_Armenian_khe),
    ("Armenian_ligature_ew", KEY_Armenian_ligature_ew),
    ("Armenian_LYUN", KEY_Armenian_LYUN),
    ("Armenian_lyun", KEY_Armenian_lyun),
    ("Armenian_MEN", KEY_Armenian_MEN),
    ("Armenian_men", KEY_Armenian_men),
    ("Armenian_NU", KEY_Armenian_NU),
    ("Armenian_nu", KEY_Armenian_nu),
    ("Armenian_O", KEY_Armenian_O),
    ("Armenian_o", KEY_Armenian_o),
    ("Armenian_paruyk", KEY_Armenian_paruyk),
    ("Armenian_PE", KEY_Armenian_PE),
    ("Armenian_pe", KEY_Armenian_pe),
    ("Armenian_PYUR", KEY_Armenian_PYUR),
    ("Armenian_pyur", KEY_Armenian_pyur),
    ("Armenian_question", KEY_Armenian_question),
    ("Armenian_RA", KEY_Armenian_RA),
    ("Armenian_ra", KEY_Armenian_ra),
    ("Armenian_RE", KEY_Armenian_RE),
    ("Armenian_re", KEY_Armenian_re),
    ("Armenian_SE", KEY_Armenian_SE),
    ("Armenian_se", KEY_Armenian_se),
    ("Armenian_separation_mark", KEY_Armenian_separation_mark),
    ("Armenian_SHA", KEY_Armenian_SHA),
    ("Armenian_sha", KEY_Armenian_sha),
    ("Armenian_shesht", KEY_Armenian_shesht),
    ("Armenian_TCHE", KEY_Armenian_TCHE),
    ("Armenian_tche", KEY_Armenian_tche),
    ("Armenian_TO", KEY_Armenian_TO),
    ("Armenian_to", KEY_Armenian_to),
    ("Armenian_TSA", KEY_Armenian_TSA),
    ("Armenian_tsa", KEY_Armenian_tsa),
    ("Armenian_TSO", KEY_Armenian_TSO),
    ("Armenian_tso", KEY_Armenian_tso),
    ("Armenian_TYUN", KEY_Armenian_TYUN),
    ("Armenian_tyun", KEY_Armenian_tyun),
    ("Armenian_verjaket", KEY_Armenian_verjaket),
    ("Armenian_VEV", KEY_Armenian_VEV),
    ("Armenian_vev", KEY_Armenian_vev),
    ("Armenian_VO", KEY_Armenian_VO),
    ("Armenian_vo", KEY_Armenian_vo),
    ("Armenian_VYUN", KEY_Armenian_VYUN),
    ("Armenian_vyun", KEY_Armenian_vyun),
    ("Armenian_YECH", KEY_Armenian_YECH),
    ("Armenian_yech", KEY_Armenian_yech),
    ("Armenian_yentamna", KEY_Armenian_yentamna),
    ("Armenian_ZA", KEY_Armenian_ZA),
    ("Armenian_za", KEY_Armenian_za),
    ("Armenian_ZHE", KEY_Armenian_ZHE),
    ("Armenian_zhe", KEY_Armenian_zhe),
    ("asciicircum", KEY_asciicircum),
    ("asciitilde", KEY_asciitilde),
    ("asterisk", KEY_asterisk),
    ("at", KEY_at),
    ("Atilde", KEY_Atilde),
    ("atilde", KEY_atilde),
    ("AudibleBell_Enable", KEY_AudibleBell_Enable),
    ("B", KEY_B),
    ("b", KEY_b),
    ("Babovedot", KEY_Babovedot),
    ("babovedot", KEY_babovedot),
    ("backslash", KEY_backslash),
    ("BackSpace", KEY_BackSpace),
    ("BackTab", KEY_BackTab),
    ("ballotcross", KEY_ballotcross),
    ("bar", KEY_bar),
    ("because", KEY_because),
    ("Begin", KEY_Begin),
    ("blank", KEY_blank),
    ("block", KEY_block),
    ("botintegral", KEY_botintegral),
    ("botleftparens", KEY_botleftparens),
    ("botleftsqbracket", KEY_botleftsqbracket),
    ("botleftsummation", KEY_botleftsummation),
    ("botrightparens", KEY_botrightparens),
    ("botrightsqbracket", KEY_botrightsqbracket),
    ("botrightsummation", KEY_botrightsummation),
    ("bott", KEY_bott),
    ("botvertsummationconnector", KEY_botvertsummationconnector),
    ("BounceKeys_Enable", KEY_BounceKeys_Enable),
    ("braceleft", KEY_braceleft),
    ("braceright", KEY_braceright),
    ("bracketleft", KEY_bracketleft),
    ("bracketright", KEY_bracketright),
    ("braille_blank", KEY_braille_blank),
    ("braille_dot_1", KEY_braille_dot_1),
    ("braille_dot_10", KEY_braille_dot_10),
    ("braille_dot_2", KEY_braille_dot_2),
    ("braille_dot_3", KEY_braille_dot_3),
    ("braille_dot_4", KEY_braille_dot_4),
    ("braille_dot_5", KEY_braille_dot_5),
    ("braille_dot_6", KEY_braille_dot_6),
    ("braille_dot_7", KEY_braille_dot_7),
    ("braille_dot_8", KEY_braille_dot_8),
    ("braille_dot_9", KEY_braille_dot_9),
    ("braille_dots_1", KEY_braille_dots_1),
    ("braille_dots_12", KEY_braille_dots_12),
    ("braille_dots_123", KEY_braille_dots_123),
    ("braille_dots_1234", KEY_braille_dots_1234),
    ("braille_dots_12345", KEY_braille_dots_12345),
    ("braille_dots_123456", KEY_braille_dots_123456),
    ("braille_dots_1234567", KEY_braille_dots_1234567),
    ("braille_dots_12345678", KEY_braille_dots_12345678),
    ("braille_dots_1234568", KEY_braille_dots_1234568),
    ("braille_dots_123457", KEY_braille_dots_123457),
    ("braille_dots_1234578", KEY_braille_dots_1234578),
    ("braille_dots_123458", KEY_braille_dots_123458),
    ("braille_dots_12346", KEY_braille_dots_12346),
    ("braille_dots_123467", KEY_braille_dots_123467),
    ("braille_dots_1234678", KEY_braille_dots_1234678),
    ("braille_dots_123468", KEY_braille_dots_123468),
    ("braille_dots_12347", KEY_braille_dots_12347),
    ("braille_dots_123478", KEY_braille_dots_123478),
    ("braille_dots_12348", KEY_braille_dots_12348),
    ("braille_dots_1235", KEY_braille_dots_1235),
    ("braille_dots_12356", KEY_braille_dots_12356),
    ("braille_dots_123567", KEY_braille_dots_123567),
    ("braille_dots_1235678", KEY_braille_dots_1235678),
    ("braille_dots_123568", KEY_braille_dots_123568),
    ("braille_dots_12357", KEY_braille_dots_12357),
    ("braille_dots_123578", KEY_braille_dots_123578),
    ("braille_dots_12358", KEY_braille_dots_12358),
    ("braille_dots_1236", KEY_braille_dots_1236),
    ("braille_dots_12367", KEY_braille_dots_12367),
    ("braille_dots_123678", KEY_braille_dots_123678),
    ("braille_dots_12368", KEY_braille_dots_12368),
    ("braille_dots_1237", KEY_braille_dots_1237),
    ("braille_dots_12378", KEY_braille_dots_12378),
    ("braille_dots_1238", KEY_braille_dots_1238),
    ("braille_dots_124", KEY_braille_dots_124),
    ("braille_dots_1245", KEY_braille_dots_1245),
    ("braille_dots_12456", KEY_braille_dots_12456),
    ("braille_dots_124567", KEY_braille_dots_124567),
    ("braille_dots_1245678", KEY_braille_dots_1245678),
    ("braille_dots_124568", KEY_braille_dots_124568),
    ("braille_dots_12457", KEY_braille_dots_12457),
    ("braille_dots_124578", KEY_braille_dots_124578),
    ("braille_dots_12458", KEY_braille_dots_12458),
    ("braille_dots_1246", KEY_braille_dots_1246),
    ("braille_dots_12467", KEY_braille_dots_12467),
    ("braille_dots_124678", KEY_braille_dots_124678),
    ("braille_dots_12468", KEY_braille_dots_12468),
    ("braille_dots_1247", KEY_braille_dots_1247),
    ("braille_dots_12478", KEY_braille_dots_12478),
    ("braille_dots_1248", KEY_braille_dots_1248),
    ("braille_dots_125", KEY_braille_dots_125),
    ("braille_dots_1256", KEY_braille_dots_1256),
    ("braille_dots_12567", KEY_braille_dots_12567),
    ("braille_dots_125678", KEY_braille_dots_125678),
    ("braille_dots_12568", KEY_braille_dots_12568),
    ("braille_dots_1257", KEY_braille_dots_1257),
    ("braille_dots_12578", KEY_braille_dots_12578),
    ("braille_dots_1258", KEY_braille_dots_1258),
    ("braille_dots_126", KEY_braille_dots_126),
    ("braille_dots_1267", KEY_braille_dots_1267),
    ("braille_dots_12678", KEY_braille_dots_12678),
    ("braille_dots_1268", KEY_braille_dots_1268),
    ("braille_dots_127", KEY_braille_dots_127),
    ("braille_dots_1278", KEY_braille_dots_1278),
    ("braille_dots_128", KEY_braille_dots_128),
    ("braille_dots_13", KEY_braille_dots_13),
    ("braille_dots_134", KEY_braille_dots_134),
    ("braille_dots_1345", KEY_braille_dots_1345),
    ("braille_dots_13456", KEY_braille_dots_13456),
    ("braille_dots_134567", KEY_braille_dots_134567),
    ("braille_dots_1345678", KEY_braille_dots_1345678),
    ("braille_dots_134568", KEY_braille_dots_134568),
    ("braille_dots_13457", KEY_braille_dots_13457),
    ("braille_dots_134578", KEY_braille_dots_134578),
    ("braille_dots_13458", KEY_braille_dots_13458),
    ("braille_dots_1346", KEY_braille_dots_1346),
    ("braille_dots_13467", KEY_braille_dots_13467),
    ("braille_dots_134678", KEY_braille_dots_134678),
    ("braille_dots_13468", KEY_braille_dots_13468),
    ("braille_dots_1347", KEY_braille_dots_1347),
    ("braille_dots_13478", KEY_braille_dots_13478),
    ("braille_dots_1348", KEY_braille_dots_1348),
    ("braille_dots_135", KEY_braille_dots_135),
    ("braille_dots_1356", KEY_braille_dots_1356),
    ("braille_dots_13567", KEY_braille_dots_13567),
    ("braille_dots_135678", KEY_braille_dots_135678),
    ("braille_dots_13568", KEY_braille_dots_13568),
    ("braille_dots_1357", KEY_braille_dots_1357),
    ("braille_dots_13578", KEY_braille_dots_13578),
    ("braille_dots_1358", KEY_braille_dots_1358),
    ("braille_dots_136", KEY_braille_dots_136),
    ("braille_dots_1367", KEY_braille_dots_1367),
    ("braille_dots_13678", KEY_braille_dots_13678),
    ("braille_dots_1368", KEY_braille_dots_1368),
    ("braille_dots_137", KEY_braille_dots_137),
    ("braille_dots_1378", KEY_braille_dots_1378),
    ("braille_dots_138", KEY_braille_dots_138),
    ("braille_dots_14", KEY_braille_dots_14),
    ("braille_dots_145", KEY_braille_dots_145),
    ("braille_dots_1456", KEY_braille_dots_1456),
    ("braille_dots_14567", KEY_braille_dots_14567),
    ("braille_dots_145678", KEY_braille_dots_145678),
    ("braille_dots_14568", KEY_braille_dots_14568),
    ("braille_dots_1457", KEY_braille_dots_1457),
    ("braille_dots_14578", KEY_braille_dots_14578),
    ("braille_dots_1458", KEY_braille_dots_1458),
    ("braille_dots_146", KEY_braille_dots_146),
    ("braille_dots_1467", KEY_braille_dots_1467),
    ("braille_dots_14678", KEY_braille_dots_14678),
    ("braille_dots_1468", KEY_braille_dots_1468),
    ("braille_dots_147", KEY_braille_dots_147),
    ("braille_dots_1478", KEY_braille_dots_1478),
    ("braille_dots_148", KEY_braille_dots_148),
    ("braille_dots_15", KEY_braille_dots_15),
    ("braille_dots_156", KEY_braille_dots_156),
    ("braille_dots_1567", KEY_braille_dots_1567),
    ("braille_dots_15678", KEY_braille_dots_15678),
    ("braille_dots_1568", KEY_braille_dots_1568),
    ("braille_dots_157", KEY_braille_dots_157),
    ("braille_dots_1578", KEY_braille_dots_1578),
    ("braille_dots_158", KEY_braille_dots_158),
    ("braille_dots_16", KEY_braille_dots_16),
    ("braille_dots_167", KEY_braille_dots_167),
    ("braille_dots_1678", KEY_braille_dots_1678),
    ("braille_dots_168", KEY_braille_dots_168),
    ("braille_dots_17", KEY_braille_dots_17),
    ("braille_dots_178", KEY_braille_dots_178),
    ("braille_dots_18", KEY_braille_dots_18),
    ("braille_dots_2", KEY_braille_dots_2),
    ("braille_dots_23", KEY_braille_dots_23),
    ("braille_dots_234", KEY_braille_dots_234),
    ("braille_dots_2345", KEY_braille_dots_2345),
    ("braille_dots_23456", KEY_braille_dots_23456),
    ("braille_dots_234567", KEY_braille_dots_234567),
    ("braille_dots_2345678", KEY_braille_dots_2345678),
    ("braille_dots_234568", KEY_braille_dots_234568),
    ("braille_dots_23457", KEY_braille_dots_23457),
    ("braille_dots_234578", KEY_braille_dots_234578),
    ("braille_dots_23458", KEY_braille_dots_23458),
    ("braille_dots_2346", KEY_braille_dots_2346),
    ("braille_dots_23467", KEY_braille_dots_23467),
    ("braille_dots_234678", KEY_braille_dots_234678),
    ("braille_dots_23468", KEY_braille_dots_23468),
    ("braille_dots_2347", KEY_braille_dots_2347),
    ("braille_dots_23478", KEY_braille_dots_23478),
    ("braille_dots_2348", KEY_braille_dots_2348),
    ("braille_dots_235", KEY_braille_dots_235),
    ("braille_dots_2356", KEY_braille_dots_2356),
    ("braille_dots_23567", KEY_braille_dots_23567),
    ("braille_dots_235678", KEY_braille_dots_235678),
    ("braille_dots_23568", KEY_braille_dots_23568),
    ("braille_dots_2357", KEY_braille_dots_2357),
    ("braille_dots_23578", KEY_braille_dots_23578),
    ("braille_dots_2358", KEY_braille_dots_2358),
    ("braille_dots_236", KEY_braille_dots_236),
    ("braille_dots_2367", KEY_braille_dots_2367),
    ("braille_dots_23678", KEY_braille_dots_23678),
    ("braille_dots_2368", KEY_braille_dots_2368),
    ("braille_dots_237", KEY_braille_dots_237),
    ("braille_dots_2378", KEY_braille_dots_2378),
    ("braille_dots_238", KEY_braille_dots_238),
    ("braille_dots_24", KEY_braille_dots_24),
    ("braille_dots_245", KEY_braille_dots_245),
    ("braille_dots_2456", KEY_braille_dots_2456),
    ("braille_dots_24567", KEY_braille_dots_24567),
    ("braille_dots_245678", KEY_braille_dots_245678),
    ("braille_dots_24568", KEY_braille_dots_24568),
    ("braille_dots_2457", KEY_braille_dots_2457),
    ("braille_dots_24578", KEY_braille_dots_24578),
    ("braille_dots_2458", KEY_braille_dots_2458),
    ("braille_dots_246", KEY_braille_dots_246),
    ("braille_dots_2467", KEY_braille_dots_2467),
    ("braille_dots_24678", KEY_braille_dots_24678),
    ("braille_dots_2468", KEY_braille_dots_2468),
    ("braille_dots_247", KEY_braille_dots_247),
    ("braille_dots_2478", KEY_braille_dots_2478),
    ("braille_dots_248", KEY_braille_dots_248),
    ("braille_dots_25", KEY_braille_dots_25),
    ("braille_dots_256", KEY_braille_dots_256),
    ("braille_dots_2567", KEY_braille_dots_2567),
    ("braille_dots_25678", KEY_braille_dots_25678),
    ("braille_dots_2568", KEY_braille_dots_2568),
    ("braille_dots_257", KEY_braille_dots_257),
    ("braille_dots_2578", KEY_braille_dots_2578),
    ("braille_dots_258", KEY_braille_dots_258),
    ("braille_dots_26", KEY_braille_dots_26),
    ("braille_dots_267", KEY_braille_dots_267),
    ("braille_dots_2678", KEY_braille_dots_2678),
    ("braille_dots_268", KEY_braille_dots_268),
    ("braille_dots_27", KEY_braille_dots_27),
    ("braille_dots_278", KEY_braille_dots_278),
    ("braille_dots_28", KEY_braille_dots_28),
    ("braille_dots_3", KEY_braille_dots_3),
    ("braille_dots_34", KEY_braille_dots_34),
    ("braille_dots_345", KEY_braille_dots_345),
    ("braille_dots_3456", KEY_braille_dots_3456),
    ("braille_dots_34567", KEY_braille_dots_34567),
    ("braille_dots_345678", KEY_braille_dots_345678),
    ("braille_dots_34568", KEY_braille_dots_34568),
    ("braille_dots_3457", KEY_braille_dots_3457),
    ("braille_dots_34578", KEY_braille_dots_34578),
    ("braille_dots_3458", KEY_braille_dots_3458),
    ("braille_dots_346", KEY_braille_dots_346),
    ("braille_dots_3467", KEY_braille_dots_3467),
    ("braille_dots_34678", KEY_braille_dots_34678),
    ("braille_dots_3468", KEY_braille_dots_3468),
    ("braille_dots_347", KEY_braille_dots_347),
    ("braille_dots_3478", KEY_braille_dots_3478),
    ("braille_dots_348", KEY_braille_dots_348),
    ("braille_dots_35", KEY_braille_dots_35),
    ("braille_dots_356", KEY_braille_dots_356),
    ("braille_dots_3567", KEY_braille_dots_3567),
    ("braille_dots_35678", KEY_braille_dots_35678),
    ("braille_dots_3568", KEY_braille_dots_3568),
    ("braille_dots_357", KEY_braille_dots_357),
    ("braille_dots_3578", KEY_braille_dots_3578),
    ("braille_dots_358", KEY_braille_dots_358),
    ("braille_dots_36", KEY_braille_dots_36),
    ("braille_dots_367", KEY_braille_dots_367),
    ("braille_dots_3678", KEY_braille_dots_3678),
    ("braille_dots_368", KEY_braille_dots_368),
    ("braille_dots_37", KEY_braille_dots_37),
    ("braille_dots_378", KEY_braille_dots_378),
    ("braille_dots_38", KEY_braille_dots_38),
    ("braille_dots_4", KEY_braille_dots_4),
    ("braille_dots_45", KEY_braille_dots_45),
    ("braille_dots_456", KEY_braille_dots_456),
    ("braille_dots_4567", KEY_braille_dots_4567),
    ("braille_dots_45678", KEY_braille_dots_45678),
    ("braille_dots_4568", KEY_braille_dots_4568),
    ("braille_dots_457", KEY_braille_dots_457),
    ("braille_dots_4578", KEY_braille_dots_4578),
    ("braille_dots_458", KEY_braille_dots_458),
    ("braille_dots_46", KEY_braille_dots_46),
    ("braille_dots_467", KEY_braille_dots_467),
    ("braille_dots_4678", KEY_braille_dots_4678),
    ("braille_dots_468", KEY_braille_dots_468),
    ("braille_dots_47", KEY_braille_dots_47),
    ("braille_dots_478", KEY_braille_dots_478),
    ("braille_dots_48", KEY_braille_dots_48),
    ("braille_dots_5", KEY_braille_dots_5),
    ("braille_dots_56", KEY_braille_dots_56),
    ("braille_dots_567", KEY_braille_dots_567),
    ("braille_dots_5678", KEY_braille_dots_5678),
    ("braille_dots_568", KEY_braille_dots_568),
    ("braille_dots_57", KEY_braille_dots_57),
    ("braille_dots_578", KEY_braille_dots_578),
    ("braille_dots_58", KEY_braille_dots_58),
    ("braille_dots_6", KEY_braille_dots_6),
    ("braille_dots_67", KEY_braille_dots_67),
    ("braille_dots_678", KEY_braille_dots_678),
    ("braille_dots_68", KEY_braille_dots_68),
    ("braille_dots_7", KEY_braille_dots_7),
    ("braille_dots_78", KEY_braille_dots_78),
    ("braille_dots_8", KEY_braille_dots_8),
    ("Break", KEY_Break),
    ("breve", KEY_breve),
    ("brokenbar", KEY_brokenbar),
    ("Byelorussian_SHORTU", KEY_Byelorussian_SHORTU),
    ("Byelorussian_shortu", KEY_Byelorussian_shortu),
    ("C", KEY_C),
    ("c", KEY_c),
    ("C_H", KEY_C_H),
    ("C_h", KEY_C_h),
    ("c_h", KEY_c_h),
    ("Cabovedot", KEY_Cabovedot),
    ("cabovedot", KEY_cabovedot),
    ("Cacute", KEY_Cacute),
    ("cacute", KEY_cacute),
    ("Cancel", KEY_Cancel),
    ("Caps_Lock", KEY_Caps_Lock),
    ("careof", KEY_careof),
    ("caret", KEY_caret),
    ("caron", KEY_caron),
    ("Ccaron", KEY_Ccaron),
    ("ccaron", KEY_ccaron),
    ("Ccedilla", KEY_Ccedilla),
    ("ccedilla", KEY_ccedilla),
    ("Ccircumflex", KEY_Ccircumflex),
    ("ccircumflex", KEY_ccircumflex),
    ("cedilla", KEY_cedilla),
    ("cent", KEY_cent),
    ("CH", KEY_CH),
    ("Ch", KEY_Ch),
    ("ch", KEY_ch),
    ("checkerboard", KEY_checkerboard),
    ("checkmark", KEY_checkmark),
    ("circle", KEY_circle),
    ("Clear", KEY_Clear),
    ("ClearLine", KEY_ClearLine),
    ("club", KEY_club),
    ("Codeinput", KEY_Codeinput),
    ("colon", KEY_colon),
    ("ColonSign", KEY_ColonSign),
    ("combining_acute", KEY_combining_acute),
    ("combining_belowdot", KEY_combining_belowdot),
    ("combining_grave", KEY_combining_grave),
    ("combining_hook", KEY_combining_hook),
    ("combining_tilde", KEY_combining_tilde),
    ("comma", KEY_comma),
    ("containsas", KEY_containsas),
    ("Control_L", KEY_Control_L),
    ("Control_R", KEY_Control_R),
    ("copyright", KEY_copyright),
    ("cr", KEY_cr),
    ("crossinglines", KEY_crossinglines),
    ("CruzeiroSign", KEY_CruzeiroSign),
    ("cuberoot", KEY_cuberoot),
    ("currency", KEY_currency),
    ("cursor", KEY_cursor),
    ("Cyrillic_A", KEY_Cyrillic_A),
    ("Cyrillic_a", KEY_Cyrillic_a),
    ("Cyrillic_BE", KEY_Cyrillic_BE),
    ("Cyrillic_be", KEY_Cyrillic_be),
    ("Cyrillic_CHE", KEY_Cyrillic_CHE),
    ("Cyrillic_che", KEY_Cyrillic_che),
    ("Cyrillic_CHE_descender", KEY_Cyrillic_CHE_descender),
    ("Cyrillic_che_descender", KEY_Cyrillic_che_descender),
    ("Cyrillic_CHE_vertstroke", KEY_Cyrillic_CHE_vertstroke),
    ("Cyrillic_che_vertstroke", KEY_Cyrillic_che_vertstroke),
    ("Cyrillic_DE", KEY_Cyrillic_DE),
    ("Cyrillic_de", KEY_Cyrillic_de),
    ("Cyrillic_DZHE", KEY_Cyrillic_DZHE),
    ("Cyrillic_dzhe", KEY_Cyrillic_dzhe),
    ("Cyrillic_E", KEY_Cyrillic_E),
    ("Cyrillic_e", KEY_Cyrillic_e),
    ("Cyrillic_EF", KEY_Cyrillic_EF),
    ("Cyrillic_ef", KEY_Cyrillic_ef),
    ("Cyrillic_EL", KEY_Cyrillic_EL),
    ("Cyrillic_el", KEY_Cyrillic_el),
    ("Cyrillic_EM", KEY_Cyrillic_EM),
    ("Cyrillic_em", KEY_Cyrillic_em),
    ("Cyrillic_EN", KEY_Cyrillic_EN),
    ("Cyrillic_en", KEY_Cyrillic_en),
    ("Cyrillic_EN_descender", KEY_Cyrillic_EN_descender),
    ("Cyrillic_en_descender", KEY_Cyrillic_en_descender),
    ("Cyrillic_ER", KEY_Cyrillic_ER),
    ("Cyrillic_er", KEY_Cyrillic_er),
    ("Cyrillic_ES", KEY_Cyrillic_ES),
    ("Cyrillic_es", KEY_Cyrillic_es),
    ("Cyrillic_GHE", KEY_Cyrillic_GHE),
    ("Cyrillic_ghe", KEY_Cyrillic_ghe),
    ("Cyrillic_GHE_bar", KEY_Cyrillic_GHE_bar),
    ("Cyrillic_ghe_bar", KEY_Cyrillic_ghe_bar),
    ("Cyrillic_HA", KEY_Cyrillic_HA),
    ("Cyrillic_ha", KEY_Cyrillic_ha),
    ("Cyrillic_HA_descender", KEY_Cyrillic_HA_descender),
    ("Cyrillic_ha_descender", KEY_Cyrillic_ha_descender),
    ("Cyrillic_HARDSIGN", KEY_Cyrillic_HARDSIGN),
    ("Cyrillic_hardsign", KEY_Cyrillic_hardsign),
    ("Cyrillic_I", KEY_Cyrillic_I),
    ("Cyrillic_i", KEY_Cyrillic_i),
    ("Cyrillic_I_macron", KEY_Cyrillic_I_macron),
    ("Cyrillic_i_macron", KEY_Cyrillic_i_macron),
    ("Cyrillic_IE", KEY_Cyrillic_IE),
    ("Cyrillic_ie", KEY_Cyrillic_ie),
    ("Cyrillic_IO", KEY_Cyrillic_IO),
    ("Cyrillic_io", KEY_Cyrillic_io),
    ("Cyrillic_JE", KEY_Cyrillic_JE),
    ("Cyrillic_je", KEY_Cyrillic_je),
    ("Cyrillic_KA", KEY_Cyrillic_KA),
    ("Cyrillic_ka", KEY_Cyrillic_ka),
    ("Cyrillic_KA_descender", KEY_Cyrillic_KA_descender),
    ("Cyrillic_ka_descender", KEY_Cyrillic_ka_descender),
    ("Cyrillic_KA_vertstroke", KEY_Cyrillic_KA_vertstroke),
    ("Cyrillic_ka_vertstroke", KEY_Cyrillic_ka_vertstroke),
    ("Cyrillic_LJE", KEY_Cyrillic_LJE),
    ("Cyrillic_lje", KEY_Cyrillic_lje),
    ("Cyrillic_NJE", KEY_Cyrillic_NJE),
    ("Cyrillic_nje", KEY_Cyrillic_nje),
    ("Cyrillic_O", KEY_Cyrillic_O),
    ("Cyrillic_o", KEY_Cyrillic_o),
    ("Cyrillic_O_bar", KEY_Cyrillic_O_bar),
    ("Cyrillic_o_bar", KEY_Cyrillic_o_bar),
    ("Cyrillic_PE", KEY_Cyrillic_PE),
    ("Cyrillic_pe", KEY_Cyrillic_pe),
    ("Cyrillic_SCHWA", KEY_Cyrillic_SCHWA),
    ("Cyrillic_schwa", KEY_Cyrillic_schwa),
    ("Cyrillic_SHA", KEY_Cyrillic_SHA),
    ("Cyrillic_sha", KEY_Cyrillic_sha),
    ("Cyrillic_SHCHA", KEY_Cyrillic_SHCHA),
    ("Cyrillic_shcha", KEY_Cyrillic_shcha),
    ("Cyrillic_SHHA", KEY_Cyrillic_SHHA),
    ("Cyrillic_shha", KEY_Cyrillic_shha),
    ("Cyrillic_SHORTI", KEY_Cyrillic_SHORTI),
    ("Cyrillic_shorti", KEY_Cyrillic_shorti),
    ("Cyrillic_SOFTSIGN", KEY_Cyrillic_SOFTSIGN),
    ("Cyrillic_softsign", KEY_Cyrillic_softsign),
    ("Cyrillic_TE", KEY_Cyrillic_TE),
    ("Cyrillic_te", KEY_Cyrillic_te),
    ("Cyrillic_TSE", KEY_Cyrillic_TSE),
    ("Cyrillic_tse", KEY_Cyrillic_tse),
    ("Cyrillic_U", KEY_Cyrillic_U),
    ("Cyrillic_u", KEY_Cyrillic_u),
    ("Cyrillic_U_macron", KEY_Cyrillic_U_macron),
    ("Cyrillic_u_macron", KEY_Cyrillic_u_macron),
    ("Cyrillic_U_straight", KEY_Cyrillic_U_straight),
    ("Cyrillic_u_straight", KEY_Cyrillic_u_straight),
    ("Cyrillic_U_straight_bar", KEY_Cyrillic_U_straight_bar),
    ("Cyrillic_u_straight_bar", KEY_Cyrillic_u_straight_bar),
    ("Cyrillic_VE", KEY_Cyrillic_VE),
    ("Cyrillic_ve", KEY_Cyrillic_ve),
    ("Cyrillic_YA", KEY_Cyrillic_YA),
    ("Cyrillic_ya", KEY_Cyrillic_ya),
    ("Cyrillic_YERU", KEY_Cyrillic_YERU),
    ("Cyrillic_yeru", KEY_Cyrillic_yeru),
    ("Cyrillic_YU", KEY_Cyrillic_YU),
    ("Cyrillic_yu", KEY_Cyrillic_yu),
    ("Cyrillic_ZE", KEY_Cyrillic_ZE),
    ("Cyrillic_ze", KEY_Cyrillic_ze),
    ("Cyrillic_ZHE", KEY_Cyrillic_ZHE),
    ("Cyrillic_zhe", KEY_Cyrillic_zhe),
    ("Cyrillic_ZHE_descender", KEY_Cyrillic_ZHE_descender),
    ("Cyrillic_zhe_descender", KEY_Cyrillic_zhe_descender),
    ("D", KEY_D),
    ("d", KEY_d),
    ("Dabovedot", KEY_Dabovedot),
    ("dabovedot", KEY_dabovedot),
    ("Dacute_accent", KEY_Dacute_accent),
    ("dagger", KEY_dagger),
    ("Dcaron", KEY_Dcaron),
    ("dcaron", KEY_dcaron),
    ("Dcedilla_accent", KEY_Dcedilla_accent),
    ("Dcircumflex_accent", KEY_Dcircumflex_accent),
    ("Ddiaeresis", KEY_Ddiaeresis),
    ("dead_A", KEY_dead_A),
    ("dead_a", KEY_dead_a),
    ("dead_abovecomma", KEY_dead_abovecomma),
    ("dead_abovedot", KEY_dead_abovedot),
    ("dead_abovereversedcomma", KEY_dead_abovereversedcomma),
    ("dead_abovering", KEY_dead_abovering),
    ("dead_aboveverticalline", KEY_dead_aboveverticalline),
    ("dead_acute", KEY_dead_acute),
    ("dead_belowbreve", KEY_dead_belowbreve),
    ("dead_belowcircumflex", KEY_dead_belowcircumflex),
    ("dead_belowcomma", KEY_dead_belowcomma),
    ("dead_belowdiaeresis", KEY_dead_belowdiaeresis),
    ("dead_belowdot", KEY_dead_belowdot),
    ("dead_belowmacron", KEY_dead_belowmacron),
    ("dead_belowring", KEY_dead_belowring),
    ("dead_belowtilde", KEY_dead_belowtilde),
    ("dead_belowverticalline", KEY_dead_belowverticalline),
    ("dead_breve", KEY_dead_breve),
    ("dead_capital_schwa", KEY_dead_capital_schwa),
    ("dead_caron", KEY_dead_caron),
    ("dead_cedilla", KEY_dead_cedilla),
    ("dead_circumflex", KEY_dead_circumflex),
    ("dead_currency", KEY_dead_currency),
    ("dead_dasia", KEY_dead_dasia),
    ("dead_diaeresis", KEY_dead_diaeresis),
    ("dead_doubleacute", KEY_dead_doubleacute),
    ("dead_doublegrave", KEY_dead_doublegrave),
    ("dead_E", KEY_dead_E),
    ("dead_e", KEY_dead_e),
    ("dead_grave", KEY_dead_grave),
    ("dead_greek", KEY_dead_greek),
    ("dead_hamza", KEY_dead_hamza),
    ("dead_hook", KEY_dead_hook),
    ("dead_horn", KEY_dead_horn),
    ("dead_I", KEY_dead_I),
    ("dead_i", KEY_dead_i),
    ("dead_invertedbreve", KEY_dead_invertedbreve),
    ("dead_iota", KEY_dead_iota),
    ("dead_longsolidusoverlay", KEY_dead_longsolidusoverlay),
    ("dead_lowline", KEY_dead_lowline),
    ("dead_macron", KEY_dead_macron),
    ("dead_O", KEY_dead_O),
    ("dead_o", KEY_dead_o),
    ("dead_ogonek", KEY_dead_ogonek),
    ("dead_perispomeni", KEY_dead_perispomeni),
    ("dead_psili", KEY_dead_psili),
    ("dead_SCHWA", KEY_dead_SCHWA),
    ("dead_schwa", KEY_dead_schwa),
    ("dead_semivoiced_sound", KEY_dead_semivoiced_sound),
    ("dead_small_schwa", KEY_dead_small_schwa),
    ("dead_stroke", KEY_dead_stroke),
    ("dead_tilde", KEY_dead_tilde),
    ("dead_U", KEY_dead_U),
    ("dead_u", KEY_dead_u),
    ("dead_voiced_sound", KEY_dead_voiced_sound),
    ("decimalpoint", KEY_decimalpoint),
    ("degree", KEY_degree),
    ("Delete", KEY_Delete),
    ("DeleteChar", KEY_DeleteChar),
    ("DeleteLine", KEY_DeleteLine),
    ("Dgrave_accent", KEY_Dgrave_accent),
    ("diaeresis", KEY_diaeresis),
    ("diamond", KEY_diamond),
    ("digitspace", KEY_digitspace),
    ("dintegral", KEY_dintegral),
    ("division", KEY_division),
    ("dollar", KEY_dollar),
    ("DongSign", KEY_DongSign),
    ("doubbaselinedot", KEY_doubbaselinedot),
    ("doubleacute", KEY_doubleacute),
    ("doubledagger", KEY_doubledagger),
    ("doublelowquotemark", KEY_doublelowquotemark),
    ("Down", KEY_Down),
    ("downarrow", KEY_downarrow),
    ("downcaret", KEY_downcaret),
    ("downshoe", KEY_downshoe),
    ("downstile", KEY_downstile),
    ("downtack", KEY_downtack),
    ("DRemove", KEY_DRemove),
    ("Dring_accent", KEY_Dring_accent),
    ("Dstroke", KEY_Dstroke),
    ("dstroke", KEY_dstroke),
    ("Dtilde", KEY_Dtilde),
    ("E", KEY_E),
    ("e", KEY_e),
    ("Eabovedot", KEY_Eabovedot),
    ("eabovedot", KEY_eabovedot),
    ("Eacute", KEY_Eacute),
    ("eacute", KEY_eacute),
    ("Ebelowdot", KEY_Ebelowdot),
    ("ebelowdot", KEY_ebelowdot),
    ("Ecaron", KEY_Ecaron),
    ("ecaron", KEY_ecaron),
    ("Ecircumflex", KEY_Ecircumflex),
    ("ecircumflex", KEY_ecircumflex),
    ("Ecircumflexacute", KEY_Ecircumflexacute),
    ("ecircumflexacute", KEY_ecircumflexacute),
    ("Ecircumflexbelowdot", KEY_Ecircumflexbelowdot),
    ("ecircumflexbelowdot", KEY_ecircumflexbelowdot),
    ("Ecircumflexgrave", KEY_Ecircumflexgrave),
    ("ecircumflexgrave", KEY_ecircumflexgrave),
    ("Ecircumflexhook", KEY_Ecircumflexhook),
    ("ecircumflexhook", KEY_ecircumflexhook),
    ("Ecircumflextilde", KEY_Ecircumflextilde),
    ("ecircumflextilde", KEY_ecircumflextilde),
    ("EcuSign", KEY_EcuSign),
    ("Ediaeresis", KEY_Ediaeresis),
    ("ediaeresis", KEY_ediaeresis),
    ("Egrave", KEY_Egrave),
    ("egrave", KEY_egrave),
    ("Ehook", KEY_Ehook),
    ("ehook", KEY_ehook),
    ("eightsubscript", KEY_eightsubscript),
    ("eightsuperior", KEY_eightsuperior),
    ("Eisu_Shift", KEY_Eisu_Shift),
    ("Eisu_toggle", KEY_Eisu_toggle),
    ("elementof", KEY_elementof),
    ("ellipsis", KEY_ellipsis),
    ("em3space", KEY_em3space),
    ("em4space", KEY_em4space),
    ("Emacron", KEY_Emacron),
    ("emacron", KEY_emacron),
    ("emdash", KEY_emdash),
    ("emfilledcircle", KEY_emfilledcircle),
    ("emfilledrect", KEY_emfilledrect),
    ("emopencircle", KEY_emopencircle),
    ("emopenrectangle", KEY_emopenrectangle),
    ("emptyset", KEY_emptyset),
    ("emspace", KEY_emspace),
    ("End", KEY_End),
    ("endash", KEY_endash),
    ("enfilledcircbullet", KEY_enfilledcircbullet),
    ("enfilledsqbullet", KEY_enfilledsqbullet),
    ("ENG", KEY_ENG),
    ("eng", KEY_eng),
    ("enopencircbullet", KEY_enopencircbullet),
    ("enopensquarebullet", KEY_enopensquarebullet),
    ("enspace", KEY_enspace),
    ("Eogonek", KEY_Eogonek),
    ("eogonek", KEY_eogonek),
    ("equal", KEY_equal),
    ("Escape", KEY_Escape),
    ("ETH", KEY_ETH),
    ("Eth", KEY_Eth),
    ("eth", KEY_eth),
    ("Etilde", KEY_Etilde),
    ("etilde", KEY_etilde),
    ("EuroSign", KEY_EuroSign),
    ("exclam", KEY_exclam),
    ("exclamdown", KEY_exclamdown),
    ("Execute", KEY_Execute),
    ("Ext16bit_L", KEY_Ext16bit_L),
    ("Ext16bit_R", KEY_Ext16bit_R),
    ("EZH", KEY_EZH),
    ("ezh", KEY_ezh),
    ("F", KEY_F),
    ("f", KEY_f),
    ("F1", KEY_F1),
    ("F10", KEY_F10),
    ("F11", KEY_F11),
    ("F12", KEY_F12),
    ("F13", KEY_F13),
    ("F14", KEY_F14),
    ("F15", KEY_F15),
    ("F16", KEY_F16),
    ("F17", KEY_F17),
    ("F18", KEY_F18),
    ("F19", KEY_F19),
    ("F2", KEY_F2),
    ("F20", KEY_F20),
    ("F21", KEY_F21),
    ("F22", KEY_F22),
    ("F23", KEY_F23),
    ("F24", KEY_F24),
    ("F25", KEY_F25),
    ("F26", KEY_F26),
    ("F27", KEY_F27),
    ("F28", KEY_F28),
    ("F29", KEY_F29),
    ("F3", KEY_F3),
    ("F30", KEY_F30),
    ("F31", KEY_F31),
    ("F32", KEY_F32),
    ("F33", KEY_F33),
    ("F34", KEY_F34),
    ("F35", KEY_F35),
    ("F4", KEY_F4),
    ("F5", KEY_F5),
    ("F6", KEY_F6),
    ("F7", KEY_F7),
    ("F8", KEY_F8),
    ("F9", KEY_F9),
    ("Fabovedot", KEY_Fabovedot),
    ("fabovedot", KEY_fabovedot),
    ("Farsi_0", KEY_Farsi_0),
    ("Farsi_1", KEY_Farsi_1),
    ("Farsi_2", KEY_Farsi_2),
    ("Farsi_3", KEY_Farsi_3),
    ("Farsi_4", KEY_Farsi_4),
    ("Farsi_5", KEY_Farsi_5),
    ("Farsi_6", KEY_Farsi_6),
    ("Farsi_7", KEY_Farsi_7),
    ("Farsi_8", KEY_Farsi_8),
    ("Farsi_9", KEY_Farsi_9),
    ("Farsi_yeh", KEY_Farsi_yeh),
    ("femalesymbol", KEY_femalesymbol),
    ("ff", KEY_ff),
    ("FFrancSign", KEY_FFrancSign),
    ("figdash", KEY_figdash),
    ("filledlefttribullet", KEY_filledlefttribullet),
    ("filledrectbullet", KEY_filledrectbullet),
    ("filledrighttribullet", KEY_filledrighttribullet),
    ("filledtribulletdown", KEY_filledtribulletdown),
    ("filledtribulletup", KEY_filledtribulletup),
    ("Find", KEY_Find),
    ("First_Virtual_Screen", KEY_First_Virtual_Screen),
    ("fiveeighths", KEY_fiveeighths),
    ("fivesixths", KEY_fivesixths),
    ("fivesubscript", KEY_fivesubscript),
    ("fivesuperior", KEY_fivesuperior),
    ("fourfifths", KEY_fourfifths),
    ("foursubscript", KEY_foursubscript),
    ("foursuperior", KEY_foursuperior),
    ("fourthroot", KEY_fourthroot),
    ("function", KEY_function),
    ("G", KEY_G),
    ("g", KEY_g),
    ("Gabovedot", KEY_Gabovedot),
    ("gabovedot", KEY_gabovedot),
    ("Gbreve", KEY_Gbreve),
    ("gbreve", KEY_gbreve),
    ("Gcaron", KEY_Gcaron),
    ("gcaron", KEY_gcaron),
    ("Gcedilla", KEY_Gcedilla),
    ("gcedilla", KEY_gcedilla),
    ("Gcircumflex", KEY_Gcircumflex),
    ("gcircumflex", KEY_gcircumflex),
    ("Georgian_an", KEY_Georgian_an),
    ("Georgian_ban", KEY_Georgian_ban),
    ("Georgian_can", KEY_Georgian_can),
    ("Georgian_char", KEY_Georgian_char),
    ("Georgian_chin", KEY_Georgian_chin),
    ("Georgian_cil", KEY_Georgian_cil),
    ("Georgian_don", KEY_Georgian_don),
    ("Georgian_en", KEY_Georgian_en),
    ("Georgian_fi", KEY_Georgian_fi),
    ("Georgian_gan", KEY_Georgian_gan),
    ("Georgian_ghan", KEY_Georgian_ghan),
    ("Georgian_hae", KEY_Georgian_hae),
    ("Georgian_har", KEY_Georgian_har),
    ("Georgian_he", KEY_Georgian_he),
    ("Georgian_hie", KEY_Georgian_hie),
    ("Georgian_hoe", KEY_Georgian_hoe),
    ("Georgian_in", KEY_Georgian_in),
    ("Georgian_jhan", KEY_Georgian_jhan),
    ("Georgian_jil", KEY_Georgian_jil),
    ("Georgian_kan", KEY_Georgian_kan),
    ("Georgian_khar", KEY_Georgian_khar),
    ("Georgian_las", KEY_Georgian_las),
    ("Georgian_man", KEY_Georgian_man),
    ("Georgian_nar", KEY_Georgian_nar),
    ("Georgian_on", KEY_Georgian_on),
    ("Georgian_par", KEY_Georgian_par),
    ("Georgian_phar", KEY_Georgian_phar),
    ("Georgian_qar", KEY_Georgian_qar),
    ("Georgian_rae", KEY_Georgian_rae),
    ("Georgian_san", KEY_Georgian_san),
    ("Georgian_shin", KEY_Georgian_shin),
    ("Georgian_tan", KEY_Georgian_tan),
    ("Georgian_tar", KEY_Georgian_tar),
    ("Georgian_un", KEY_Georgian_un),
    ("Georgian_vin", KEY_Georgian_vin),
    ("Georgian_we", KEY_Georgian_we),
    ("Georgian_xan", KEY_Georgian_xan),
    ("Georgian_zen", KEY_Georgian_zen),
    ("Georgian_zhar", KEY_Georgian_zhar),
    ("grave", KEY_grave),
    ("greater", KEY_greater),
    ("greaterthanequal", KEY_greaterthanequal),
    ("Greek_accentdieresis", KEY_Greek_accentdieresis),
    ("Greek_ALPHA", KEY_Greek_ALPHA),
    ("Greek_alpha", KEY_Greek_alpha),
    ("Greek_ALPHAaccent", KEY_Greek_ALPHAaccent),
    ("Greek_alphaaccent", KEY_Greek_alphaaccent),
    ("Greek_BETA", KEY_Greek_BETA),
    ("Greek_beta", KEY_Greek_beta),
    ("Greek_CHI", KEY_Greek_CHI),
    ("Greek_chi", KEY_Greek_chi),
    ("Greek_DELTA", KEY_Greek_DELTA),
    ("Greek_delta", KEY_Greek_delta),
    ("Greek_EPSILON", KEY_Greek_EPSILON),
    ("Greek_epsilon", KEY_Greek_epsilon),
    ("Greek_EPSILONaccent", KEY_Greek_EPSILONaccent),
    ("Greek_epsilonaccent", KEY_Greek_epsilonaccent),
    ("Greek_ETA", KEY_Greek_ETA),
    ("Greek_eta", KEY_Greek_eta),
    ("Greek_ETAaccent", KEY_Greek_ETAaccent),
    ("Greek_etaaccent", KEY_Greek_etaaccent),
    ("Greek_finalsmallsigma", KEY_Greek_finalsmallsigma),
    ("Greek_GAMMA", KEY_Greek_GAMMA),
    ("Greek_gamma", KEY_Greek_gamma),
    ("Greek_horizbar", KEY_Greek_horizbar),
    ("Greek_IOTA", KEY_Greek_IOTA),
    ("Greek_iota", KEY_Greek_iota),
    ("Greek_IOTAaccent", KEY_Greek_IOTAaccent),
    ("Greek_iotaaccent", KEY_Greek_iotaaccent),
    ("Greek_iotaaccentdieresis", KEY_Greek_iotaaccentdieresis),
    ("Greek_IOTAdiaeresis", KEY_Greek_IOTAdiaeresis),
    ("Greek_IOTAdieresis", KEY_Greek_IOTAdieresis),
    ("Greek_iotadieresis", KEY_Greek_iotadieresis),
    ("Greek_KAPPA", KEY_Greek_KAPPA),
    ("Greek_kappa", KEY_Greek_kappa),
    ("Greek_LAMBDA", KEY_Greek_LAMBDA),
    ("Greek_lambda", KEY_Greek_lambda),
    ("Greek_LAMDA", KEY_Greek_LAMDA),
    ("Greek_lamda", KEY_Greek_lamda),
    ("Greek_MU", KEY_Greek_MU),
    ("Greek_mu", KEY_Greek_mu),
    ("Greek_NU", KEY_Greek_NU),
    ("Greek_nu", KEY_Greek_nu),
    ("Greek_OMEGA", KEY_Greek_OMEGA),
    ("Greek_omega", KEY_Greek_omega),
    ("Greek_OMEGAaccent", KEY_Greek_OMEGAaccent),
    ("Greek_omegaaccent", KEY_Greek_omegaaccent),
    ("Greek_OMICRON", KEY_Greek_OMICRON),
    ("Greek_omicron", KEY_Greek_omicron),
    ("Greek_OMICRONaccent", KEY_Greek_OMICRONaccent),
    ("Greek_omicronaccent", KEY_Greek_omicronaccent),
    ("Greek_PHI", KEY_Greek_PHI),
    ("Greek_phi", KEY_Greek_phi),
    ("Greek_PI", KEY_Greek_PI),
    ("Greek_pi", KEY_Greek_pi),
    ("Greek_PSI", KEY_Greek_PSI),
    ("Greek_psi", KEY_Greek_psi),
    ("Greek_RHO", KEY_Greek_RHO),
    ("Greek_rho", KEY_Greek_rho),
    ("Greek_SIGMA", KEY_Greek_SIGMA),
    ("Greek_sigma", KEY_Greek_sigma),
    ("Greek_switch", KEY_Greek_switch),
    ("Greek_TAU", KEY_Greek_TAU),
    ("Greek_tau", KEY_Greek_tau),
    ("Greek_THETA", KEY_Greek_THETA),
    ("Greek_theta", KEY_Greek_theta),
    ("Greek_UPSILON", KEY_Greek_UPSILON),
    ("Greek_upsilon", KEY_Greek_upsilon),
    ("Greek_UPSILONaccent", KEY_Greek_UPSILONaccent),
    ("Greek_upsilonaccent", KEY_Greek_upsilonaccent),
    (
        "Greek_upsilonaccentdieresis",
        KEY_Greek_upsilonaccentdieresis,
    ),
    ("Greek_UPSILONdieresis", KEY_Greek_UPSILONdieresis),
    ("Greek_upsilondieresis", KEY_Greek_upsilondieresis),
    ("Greek_XI", KEY_Greek_XI),
    ("Greek_xi", KEY_Greek_xi),
    ("Greek_ZETA", KEY_Greek_ZETA),
    ("Greek_zeta", KEY_Greek_zeta),
    ("guilder", KEY_guilder),
    ("guillemetleft", KEY_guillemetleft),
    ("guillemetright", KEY_guillemetright),
    ("guillemotleft", KEY_guillemotleft),
    ("guillemotright", KEY_guillemotright),
    ("H", KEY_H),
    ("h", KEY_h),
    ("hairspace", KEY_hairspace),
    ("Hangul", KEY_Hangul),
    ("Hangul_A", KEY_Hangul_A),
    ("Hangul_AE", KEY_Hangul_AE),
    ("Hangul_AraeA", KEY_Hangul_AraeA),
    ("Hangul_AraeAE", KEY_Hangul_AraeAE),
    ("Hangul_Banja", KEY_Hangul_Banja),
    ("Hangul_Cieuc", KEY_Hangul_Cieuc),
    ("Hangul_Codeinput", KEY_Hangul_Codeinput),
    ("Hangul_Dikeud", KEY_Hangul_Dikeud),
    ("Hangul_E", KEY_Hangul_E),
    ("Hangul_End", KEY_Hangul_End),
    ("Hangul_EO", KEY_Hangul_EO),
    ("Hangul_EU", KEY_Hangul_EU),
    ("Hangul_Hanja", KEY_Hangul_Hanja),
    ("Hangul_Hieuh", KEY_Hangul_Hieuh),
    ("Hangul_I", KEY_Hangul_I),
    ("Hangul_Ieung", KEY_Hangul_Ieung),
    ("Hangul_J_Cieuc", KEY_Hangul_J_Cieuc),
    ("Hangul_J_Dikeud", KEY_Hangul_J_Dikeud),
    ("Hangul_J_Hieuh", KEY_Hangul_J_Hieuh),
    ("Hangul_J_Ieung", KEY_Hangul_J_Ieung),
    ("Hangul_J_Jieuj", KEY_Hangul_J_Jieuj),
    ("Hangul_J_Khieuq", KEY_Hangul_J_Khieuq),
    ("Hangul_J_Kiyeog", KEY_Hangul_J_Kiyeog),
    ("Hangul_J_KiyeogSios", KEY_Hangul_J_KiyeogSios),
    ("Hangul_J_KkogjiDalrinIeung", KEY_Hangul_J_KkogjiDalrinIeung),
    ("Hangul_J_Mieum", KEY_Hangul_J_Mieum),
    ("Hangul_J_Nieun", KEY_Hangul_J_Nieun),
    ("Hangul_J_NieunHieuh", KEY_Hangul_J_NieunHieuh),
    ("Hangul_J_NieunJieuj", KEY_Hangul_J_NieunJieuj),
    ("Hangul_J_PanSios", KEY_Hangul_J_PanSios),
    ("Hangul_J_Phieuf", KEY_Hangul_J_Phieuf),
    ("Hangul_J_Pieub", KEY_Hangul_J_Pieub),
    ("Hangul_J_PieubSios", KEY_Hangul_J_PieubSios),
    ("Hangul_J_Rieul", KEY_Hangul_J_Rieul),
    ("Hangul_J_RieulHieuh", KEY_Hangul_J_RieulHieuh),
    ("Hangul_J_RieulKiyeog", KEY_Hangul_J_RieulKiyeog),
    ("Hangul_J_RieulMieum", KEY_Hangul_J_RieulMieum),
    ("Hangul_J_RieulPhieuf", KEY_Hangul_J_RieulPhieuf),
    ("Hangul_J_RieulPieub", KEY_Hangul_J_RieulPieub),
    ("Hangul_J_RieulSios", KEY_Hangul_J_RieulSios),
    ("Hangul_J_RieulTieut", KEY_Hangul_J_RieulTieut),
    ("Hangul_J_Sios", KEY_Hangul_J_Sios),
    ("Hangul_J_SsangKiyeog", KEY_Hangul_J_SsangKiyeog),
    ("Hangul_J_SsangSios", KEY_Hangul_J_SsangSios),
    ("Hangul_J_Tieut", KEY_Hangul_J_Tieut),
    ("Hangul_J_YeorinHieuh", KEY_Hangul_J_YeorinHieuh),
    ("Hangul_Jamo", KEY_Hangul_Jamo),
    ("Hangul_Jeonja", KEY_Hangul_Jeonja),
    ("Hangul_Jieuj", KEY_Hangul_Jieuj),
    ("Hangul_Khieuq", KEY_Hangul_Khieuq),
    ("Hangul_Kiyeog", KEY_Hangul_Kiyeog),
    ("Hangul_KiyeogSios", KEY_Hangul_KiyeogSios),
    ("Hangul_KkogjiDalrinIeung", KEY_Hangul_KkogjiDalrinIeung),
    ("Hangul_Mieum", KEY_Hangul_Mieum),
    ("Hangul_MultipleCandidate", KEY_Hangul_MultipleCandidate),
    ("Hangul_Nieun", KEY_Hangul_Nieun),
    ("Hangul_NieunHieuh", KEY_Hangul_NieunHieuh),
    ("Hangul_NieunJieuj", KEY_Hangul_NieunJieuj),
    ("Hangul_O", KEY_Hangul_O),
    ("Hangul_OE", KEY_Hangul_OE),
    ("Hangul_PanSios", KEY_Hangul_PanSios),
    ("Hangul_Phieuf", KEY_Hangul_Phieuf),
    ("Hangul_Pieub", KEY_Hangul_Pieub),
    ("Hangul_PieubSios", KEY_Hangul_PieubSios),
    ("Hangul_PostHanja", KEY_Hangul_PostHanja),
    ("Hangul_PreHanja", KEY_Hangul_PreHanja),
    ("Hangul_PreviousCandidate", KEY_Hangul_PreviousCandidate),
    ("Hangul_Rieul", KEY_Hangul_Rieul),
    ("Hangul_RieulHieuh", KEY_Hangul_RieulHieuh),
    ("Hangul_RieulKiyeog", KEY_Hangul_RieulKiyeog),
    ("Hangul_RieulMieum", KEY_Hangul_RieulMieum),
    ("Hangul_RieulPhieuf", KEY_Hangul_RieulPhieuf),
    ("Hangul_RieulPieub", KEY_Hangul_RieulPieub),
    ("Hangul_RieulSios", KEY_Hangul_RieulSios),
    ("Hangul_RieulTieut", KEY_Hangul_RieulTieut),
    ("Hangul_RieulYeorinHieuh", KEY_Hangul_RieulYeorinHieuh),
    ("Hangul_Romaja", KEY_Hangul_Romaja),
    ("Hangul_SingleCandidate", KEY_Hangul_SingleCandidate),
    ("Hangul_Sios", KEY_Hangul_Sios),
    ("Hangul_Special", KEY_Hangul_Special),
    ("Hangul_SsangDikeud", KEY_Hangul_SsangDikeud),
    ("Hangul_SsangJieuj", KEY_Hangul_SsangJieuj),
    ("Hangul_SsangKiyeog", KEY_Hangul_SsangKiyeog),
    ("Hangul_SsangPieub", KEY_Hangul_SsangPieub),
    ("Hangul_SsangSios", KEY_Hangul_SsangSios),
    ("Hangul_Start", KEY_Hangul_Start),
    ("Hangul_SunkyeongeumMieum", KEY_Hangul_SunkyeongeumMieum),
    ("Hangul_SunkyeongeumPhieuf", KEY_Hangul_SunkyeongeumPhieuf),
    ("Hangul_SunkyeongeumPieub", KEY_Hangul_SunkyeongeumPieub),
    ("Hangul_switch", KEY_Hangul_switch),
    ("Hangul_Tieut", KEY_Hangul_Tieut),
    ("Hangul_U", KEY_Hangul_U),
    ("Hangul_WA", KEY_Hangul_WA),
    ("Hangul_WAE", KEY_Hangul_WAE),
    ("Hangul_WE", KEY_Hangul_WE),
    ("Hangul_WEO", KEY_Hangul_WEO),
    ("Hangul_WI", KEY_Hangul_WI),
    ("Hangul_YA", KEY_Hangul_YA),
    ("Hangul_YAE", KEY_Hangul_YAE),
    ("Hangul_YE", KEY_Hangul_YE),
    ("Hangul_YEO", KEY_Hangul_YEO),
    ("Hangul_YeorinHieuh", KEY_Hangul_YeorinHieuh),
    ("Hangul_YI", KEY_Hangul_YI),
    ("Hangul_YO", KEY_Hangul_YO),
    ("Hangul_YU", KEY_Hangul_YU),
    ("Hankaku", KEY_Hankaku),
    ("Hcircumflex", KEY_Hcircumflex),
    ("hcircumflex", KEY_hcircumflex),
    ("heart", KEY_heart),
    ("hebrew_aleph", KEY_hebrew_aleph),
    ("hebrew_ayin", KEY_hebrew_ayin),
    ("hebrew_bet", KEY_hebrew_bet),
    ("hebrew_beth", KEY_hebrew_beth),
    ("hebrew_chet", KEY_hebrew_chet),
    ("hebrew_dalet", KEY_hebrew_dalet),
    ("hebrew_daleth", KEY_hebrew_daleth),
    ("hebrew_doublelowline", KEY_hebrew_doublelowline),
    ("hebrew_finalkaph", KEY_hebrew_finalkaph),
    ("hebrew_finalmem", KEY_hebrew_finalmem),
    ("hebrew_finalnun", KEY_hebrew_finalnun),
    ("hebrew_finalpe", KEY_hebrew_finalpe),
    ("hebrew_finalzade", KEY_hebrew_finalzade),
    ("hebrew_finalzadi", KEY_hebrew_finalzadi),
    ("hebrew_gimel", KEY_hebrew_gimel),
    ("hebrew_gimmel", KEY_hebrew_gimmel),
    ("hebrew_he", KEY_hebrew_he),
    ("hebrew_het", KEY_hebrew_het),
    ("hebrew_kaph", KEY_hebrew_kaph),
    ("hebrew_kuf", KEY_hebrew_kuf),
    ("hebrew_lamed", KEY_hebrew_lamed),
    ("hebrew_mem", KEY_hebrew_mem),
    ("hebrew_nun", KEY_hebrew_nun),
    ("hebrew_pe", KEY_hebrew_pe),
    ("hebrew_qoph", KEY_hebrew_qoph),
    ("hebrew_resh", KEY_hebrew_resh),
    ("hebrew_samech", KEY_hebrew_samech),
    ("hebrew_samekh", KEY_hebrew_samekh),
    ("hebrew_shin", KEY_hebrew_shin),
    ("Hebrew_switch", KEY_Hebrew_switch),
    ("hebrew_taf", KEY_hebrew_taf),
    ("hebrew_taw", KEY_hebrew_taw),
    ("hebrew_tet", KEY_hebrew_tet),
    ("hebrew_teth", KEY_hebrew_teth),
    ("hebrew_waw", KEY_hebrew_waw),
    ("hebrew_yod", KEY_hebrew_yod),
    ("hebrew_zade", KEY_hebrew_zade),
    ("hebrew_zadi", KEY_hebrew_zadi),
    ("hebrew_zain", KEY_hebrew_zain),
    ("hebrew_zayin", KEY_hebrew_zayin),
    ("Help", KEY_Help),
    ("Henkan", KEY_Henkan),
    ("Henkan_Mode", KEY_Henkan_Mode),
    ("hexagram", KEY_hexagram),
    ("Hiragana", KEY_Hiragana),
    ("Hiragana_Katakana", KEY_Hiragana_Katakana),
    ("Home", KEY_Home),
    ("horizconnector", KEY_horizconnector),
    ("horizlinescan1", KEY_horizlinescan1),
    ("horizlinescan3", KEY_horizlinescan3),
    ("horizlinescan5", KEY_horizlinescan5),
    ("horizlinescan7", KEY_horizlinescan7),
    ("horizlinescan9", KEY_horizlinescan9),
    ("hpBackTab", KEY_hpBackTab),
    ("hpblock", KEY_hpblock),
    ("hpClearLine", KEY_hpClearLine),
    ("hpDeleteChar", KEY_hpDeleteChar),
    ("hpDeleteLine", KEY_hpDeleteLine),
    ("hpguilder", KEY_hpguilder),
    ("hpInsertChar", KEY_hpInsertChar),
    ("hpInsertLine", KEY_hpInsertLine),
    ("hpIO", KEY_hpIO),
    ("hpKP_BackTab", KEY_hpKP_BackTab),
    ("hplira", KEY_hplira),
    ("hplongminus", KEY_hplongminus),
    ("hpModelock1", KEY_hpModelock1),
    ("hpModelock2", KEY_hpModelock2),
    ("hpmute_acute", KEY_hpmute_acute),
    ("hpmute_asciicircum", KEY_hpmute_asciicircum),
    ("hpmute_asciitilde", KEY_hpmute_asciitilde),
    ("hpmute_diaeresis", KEY_hpmute_diaeresis),
    ("hpmute_grave", KEY_hpmute_grave),
    ("hpReset", KEY_hpReset),
    ("hpSystem", KEY_hpSystem),
    ("hpUser", KEY_hpUser),
    ("hpYdiaeresis", KEY_hpYdiaeresis),
    ("Hstroke", KEY_Hstroke),
    ("hstroke", KEY_hstroke),
    ("ht", KEY_ht),
    ("Hyper_L", KEY_Hyper_L),
    ("Hyper_R", KEY_Hyper_R),
    ("hyphen", KEY_hyphen),
    ("I", KEY_I),
    ("i", KEY_i),
    ("Iabovedot", KEY_Iabovedot),
    ("Iacute", KEY_Iacute),
    ("iacute", KEY_iacute),
    ("Ibelowdot", KEY_Ibelowdot),
    ("ibelowdot", KEY_ibelowdot),
    ("Ibreve", KEY_Ibreve),
    ("ibreve", KEY_ibreve),
    ("Icircumflex", KEY_Icircumflex),
    ("icircumflex", KEY_icircumflex),
    ("identical", KEY_identical),
    ("Idiaeresis", KEY_Idiaeresis),
    ("idiaeresis", KEY_idiaeresis),
    ("idotless", KEY_idotless),
    ("ifonlyif", KEY_ifonlyif),
    ("Igrave", KEY_Igrave),
    ("igrave", KEY_igrave),
    ("Ihook", KEY_Ihook),
    ("ihook", KEY_ihook),
    ("Imacron", KEY_Imacron),
    ("imacron", KEY_imacron),
    ("implies", KEY_implies),
    ("includedin", KEY_includedin),
    ("includes", KEY_includes),
    ("infinity", KEY_infinity),
    ("Insert", KEY_Insert),
    ("InsertChar", KEY_InsertChar),
    ("InsertLine", KEY_InsertLine),
    ("integral", KEY_integral),
    ("intersection", KEY_intersection),
    ("IO", KEY_IO),
    ("Iogonek", KEY_Iogonek),
    ("iogonek", KEY_iogonek),
    ("ISO_Center_Object", KEY_ISO_Center_Object),
    ("ISO_Continuous_Underline", KEY_ISO_Continuous_Underline),
    (
        "ISO_Discontinuous_Underline",
        KEY_ISO_Discontinuous_Underline,
    ),
    ("ISO_Emphasize", KEY_ISO_Emphasize),
    ("ISO_Enter", KEY_ISO_Enter),
    ("ISO_Fast_Cursor_Down", KEY_ISO_Fast_Cursor_Down),
    ("ISO_Fast_Cursor_Left", KEY_ISO_Fast_Cursor_Left),
    ("ISO_Fast_Cursor_Right", KEY_ISO_Fast_Cursor_Right),
    ("ISO_Fast_Cursor_Up", KEY_ISO_Fast_Cursor_Up),
    ("ISO_First_Group", KEY_ISO_First_Group),
    ("ISO_First_Group_Lock", KEY_ISO_First_Group_Lock),
    ("ISO_Group_Latch", KEY_ISO_Group_Latch),
    ("ISO_Group_Lock", KEY_ISO_Group_Lock),
    ("ISO_Group_Shift", KEY_ISO_Group_Shift),
    ("ISO_Last_Group", KEY_ISO_Last_Group),
    ("ISO_Last_Group_Lock", KEY_ISO_Last_Group_Lock),
    ("ISO_Left_Tab", KEY_ISO_Left_Tab),
    ("ISO_Level2_Latch", KEY_ISO_Level2_Latch),
    ("ISO_Level3_Latch", KEY_ISO_Level3_Latch),
    ("ISO_Level3_Lock", KEY_ISO_Level3_Lock),
    ("ISO_Level3_Shift", KEY_ISO_Level3_Shift),
    ("ISO_Level5_Latch", KEY_ISO_Level5_Latch),
    ("ISO_Level5_Lock", KEY_ISO_Level5_Lock),
    ("ISO_Level5_Shift", KEY_ISO_Level5_Shift),
    ("ISO_Lock", KEY_ISO_Lock),
    ("ISO_Move_Line_Down", KEY_ISO_Move_Line_Down),
    ("ISO_Move_Line_Up", KEY_ISO_Move_Line_Up),
    ("ISO_Next_Group", KEY_ISO_Next_Group),
    ("ISO_Next_Group_Lock", KEY_ISO_Next_Group_Lock),
    ("ISO_Partial_Line_Down", KEY_ISO_Partial_Line_Down),
    ("ISO_Partial_Line_Up", KEY_ISO_Partial_Line_Up),
    ("ISO_Partial_Space_Left", KEY_ISO_Partial_Space_Left),
    ("ISO_Partial_Space_Right", KEY_ISO_Partial_Space_Right),
    ("ISO_Prev_Group", KEY_ISO_Prev_Group),
    ("ISO_Prev_Group_Lock", KEY_ISO_Prev_Group_Lock),
    ("ISO_Release_Both_Margins", KEY_ISO_Release_Both_Margins),
    ("ISO_Release_Margin_Left", KEY_ISO_Release_Margin_Left),
    ("ISO_Release_Margin_Right", KEY_ISO_Release_Margin_Right),
    ("ISO_Set_Margin_Left", KEY_ISO_Set_Margin_Left),
    ("ISO_Set_Margin_Right", KEY_ISO_Set_Margin_Right),
    ("Itilde", KEY_Itilde),
    ("itilde", KEY_itilde),
    ("J", KEY_J),
    ("j", KEY_j),
    ("Jcircumflex", KEY_Jcircumflex),
    ("jcircumflex", KEY_jcircumflex),
    ("jot", KEY_jot),
    ("K", KEY_K),
    ("k", KEY_k),
    ("kana_A", KEY_kana_A),
    ("kana_a", KEY_kana_a),
    ("kana_CHI", KEY_kana_CHI),
    ("kana_closingbracket", KEY_kana_closingbracket),
    ("kana_comma", KEY_kana_comma),
    ("kana_conjunctive", KEY_kana_conjunctive),
    ("kana_E", KEY_kana_E),
    ("kana_e", KEY_kana_e),
    ("kana_FU", KEY_kana_FU),
    ("kana_fullstop", KEY_kana_fullstop),
    ("kana_HA", KEY_kana_HA),
    ("kana_HE", KEY_kana_HE),
    ("kana_HI", KEY_kana_HI),
    ("kana_HO", KEY_kana_HO),
    ("kana_HU", KEY_kana_HU),
    ("kana_I", KEY_kana_I),
    ("kana_i", KEY_kana_i),
    ("kana_KA", KEY_kana_KA),
    ("kana_KE", KEY_kana_KE),
    ("kana_KI", KEY_kana_KI),
    ("kana_KO", KEY_kana_KO),
    ("kana_KU", KEY_kana_KU),
    ("Kana_Lock", KEY_Kana_Lock),
    ("kana_MA", KEY_kana_MA),
    ("kana_ME", KEY_kana_ME),
    ("kana_MI", KEY_kana_MI),
    ("kana_middledot", KEY_kana_middledot),
    ("kana_MO", KEY_kana_MO),
    ("kana_MU", KEY_kana_MU),
    ("kana_N", KEY_kana_N),
    ("kana_NA", KEY_kana_NA),
    ("kana_NE", KEY_kana_NE),
    ("kana_NI", KEY_kana_NI),
    ("kana_NO", KEY_kana_NO),
    ("kana_NU", KEY_kana_NU),
    ("kana_O", KEY_kana_O),
    ("kana_o", KEY_kana_o),
    ("kana_openingbracket", KEY_kana_openingbracket),
    ("kana_RA", KEY_kana_RA),
    ("kana_RE", KEY_kana_RE),
    ("kana_RI", KEY_kana_RI),
    ("kana_RO", KEY_kana_RO),
    ("kana_RU", KEY_kana_RU),
    ("kana_SA", KEY_kana_SA),
    ("kana_SE", KEY_kana_SE),
    ("kana_SHI", KEY_kana_SHI),
    ("Kana_Shift", KEY_Kana_Shift),
    ("kana_SO", KEY_kana_SO),
    ("kana_SU", KEY_kana_SU),
    ("kana_switch", KEY_kana_switch),
    ("kana_TA", KEY_kana_TA),
    ("kana_TE", KEY_kana_TE),
    ("kana_TI", KEY_kana_TI),
    ("kana_TO", KEY_kana_TO),
    ("kana_TSU", KEY_kana_TSU),
    ("kana_tsu", KEY_kana_tsu),
    ("kana_TU", KEY_kana_TU),
    ("kana_tu", KEY_kana_tu),
    ("kana_U", KEY_kana_U),
    ("kana_u", KEY_kana_u),
    ("kana_WA", KEY_kana_WA),
    ("kana_WO", KEY_kana_WO),
    ("kana_YA", KEY_kana_YA),
    ("kana_ya", KEY_kana_ya),
    ("kana_YO", KEY_kana_YO),
    ("kana_yo", KEY_kana_yo),
    ("kana_YU", KEY_kana_YU),
    ("kana_yu", KEY_kana_yu),
    ("Kanji", KEY_Kanji),
    ("Kanji_Bangou", KEY_Kanji_Bangou),
    ("kappa", KEY_kappa),
    ("Katakana", KEY_Katakana),
    ("Kcedilla", KEY_Kcedilla),
    ("kcedilla", KEY_kcedilla),
    ("Korean_Won", KEY_Korean_Won),
    ("KP_0", KEY_KP_0),
    ("KP_1", KEY_KP_1),
    ("KP_2", KEY_KP_2),
    ("KP_3", KEY_KP_3),
    ("KP_4", KEY_KP_4),
    ("KP_5", KEY_KP_5),
    ("KP_6", KEY_KP_6),
    ("KP_7", KEY_KP_7),
    ("KP_8", KEY_KP_8),
    ("KP_9", KEY_KP_9),
    ("KP_Add", KEY_KP_Add),
    ("KP_BackTab", KEY_KP_BackTab),
    ("KP_Begin", KEY_KP_Begin),
    ("KP_Decimal", KEY_KP_Decimal),
    ("KP_Delete", KEY_KP_Delete),
    ("KP_Divide", KEY_KP_Divide),
    ("KP_Down", KEY_KP_Down),
    ("KP_End", KEY_KP_End),
    ("KP_Enter", KEY_KP_Enter),
    ("KP_Equal", KEY_KP_Equal),
    ("KP_F1", KEY_KP_F1),
    ("KP_F2", KEY_KP_F2),
    ("KP_F3", KEY_KP_F3),
    ("KP_F4", KEY_KP_F4),
    ("KP_Home", KEY_KP_Home),
    ("KP_Insert", KEY_KP_Insert),
    ("KP_Left", KEY_KP_Left),
    ("KP_Multiply", KEY_KP_Multiply),
    ("KP_Next", KEY_KP_Next),
    ("KP_Page_Down", KEY_KP_Page_Down),
    ("KP_Page_Up", KEY_KP_Page_Up),
    ("KP_Prior", KEY_KP_Prior),
    ("KP_Right", KEY_KP_Right),
    ("KP_Separator", KEY_KP_Separator),
    ("KP_Space", KEY_KP_Space),
    ("KP_Subtract", KEY_KP_Subtract),
    ("KP_Tab", KEY_KP_Tab),
    ("KP_Up", KEY_KP_Up),
    ("kra", KEY_kra),
    ("L", KEY_L),
    ("l", KEY_l),
    ("L1", KEY_L1),
    ("L10", KEY_L10),
    ("L2", KEY_L2),
    ("L3", KEY_L3),
    ("L4", KEY_L4),
    ("L5", KEY_L5),
    ("L6", KEY_L6),
    ("L7", KEY_L7),
    ("L8", KEY_L8),
    ("L9", KEY_L9),
    ("Lacute", KEY_Lacute),
    ("lacute", KEY_lacute),
    ("Last_Virtual_Screen", KEY_Last_Virtual_Screen),
    ("latincross", KEY_latincross),
    ("Lbelowdot", KEY_Lbelowdot),
    ("lbelowdot", KEY_lbelowdot),
    ("Lcaron", KEY_Lcaron),
    ("lcaron", KEY_lcaron),
    ("Lcedilla", KEY_Lcedilla),
    ("lcedilla", KEY_lcedilla),
    ("Left", KEY_Left),
    ("leftanglebracket", KEY_leftanglebracket),
    ("leftarrow", KEY_leftarrow),
    ("leftcaret", KEY_leftcaret),
    ("leftdoublequotemark", KEY_leftdoublequotemark),
    ("leftmiddlecurlybrace", KEY_leftmiddlecurlybrace),
    ("leftopentriangle", KEY_leftopentriangle),
    ("leftpointer", KEY_leftpointer),
    ("leftradical", KEY_leftradical),
    ("leftshoe", KEY_leftshoe),
    ("leftsinglequotemark", KEY_leftsinglequotemark),
    ("leftt", KEY_leftt),
    ("lefttack", KEY_lefttack),
    ("less", KEY_less),
    ("lessthanequal", KEY_lessthanequal),
    ("lf", KEY_lf),
    ("Linefeed", KEY_Linefeed),
    ("lira", KEY_lira),
    ("LiraSign", KEY_LiraSign),
    ("logicaland", KEY_logicaland),
    ("logicalor", KEY_logicalor),
    ("longminus", KEY_longminus),
    ("lowleftcorner", KEY_lowleftcorner),
    ("lowrightcorner", KEY_lowrightcorner),
    ("Lstroke", KEY_Lstroke),
    ("lstroke", KEY_lstroke),
    ("M", KEY_M),
    ("m", KEY_m),
    ("Mabovedot", KEY_Mabovedot),
    ("mabovedot", KEY_mabovedot),
    ("Macedonia_DSE", KEY_Macedonia_DSE),
    ("Macedonia_dse", KEY_Macedonia_dse),
    ("Macedonia_GJE", KEY_Macedonia_GJE),
    ("Macedonia_gje", KEY_Macedonia_gje),
    ("Macedonia_KJE", KEY_Macedonia_KJE),
    ("Macedonia_kje", KEY_Macedonia_kje),
    ("macron", KEY_macron),
    ("Mae_Koho", KEY_Mae_Koho),
    ("malesymbol", KEY_malesymbol),
    ("maltesecross", KEY_maltesecross),
    ("marker", KEY_marker),
    ("masculine", KEY_masculine),
    ("Massyo", KEY_Massyo),
    ("Menu", KEY_Menu),
    ("Meta_L", KEY_Meta_L),
    ("Meta_R", KEY_Meta_R),
    ("MillSign", KEY_MillSign),
    ("minus", KEY_minus),
    ("minutes", KEY_minutes),
    ("Mode_switch", KEY_Mode_switch),
    ("MouseKeys_Accel_Enable", KEY_MouseKeys_Accel_Enable),
    ("MouseKeys_Enable", KEY_MouseKeys_Enable),
    ("mu", KEY_mu),
    ("Muhenkan", KEY_Muhenkan),
    ("Multi_key", KEY_Multi_key),
    ("MultipleCandidate", KEY_MultipleCandidate),
    ("multiply", KEY_multiply),
    ("musicalflat", KEY_musicalflat),
    ("musicalsharp", KEY_musicalsharp),
    ("mute_acute", KEY_mute_acute),
    ("mute_asciicircum", KEY_mute_asciicircum),
    ("mute_asciitilde", KEY_mute_asciitilde),
    ("mute_diaeresis", KEY_mute_diaeresis),
    ("mute_grave", KEY_mute_grave),
    ("N", KEY_N),
    ("n", KEY_n),
    ("nabla", KEY_nabla),
    ("Nacute", KEY_Nacute),
    ("nacute", KEY_nacute),
    ("NairaSign", KEY_NairaSign),
    ("Ncaron", KEY_Ncaron),
    ("ncaron", KEY_ncaron),
    ("Ncedilla", KEY_Ncedilla),
    ("ncedilla", KEY_ncedilla),
    ("NewSheqelSign", KEY_NewSheqelSign),
    ("Next", KEY_Next),
    ("Next_Virtual_Screen", KEY_Next_Virtual_Screen),
    ("ninesubscript", KEY_ninesubscript),
    ("ninesuperior", KEY_ninesuperior),
    ("nl", KEY_nl),
    ("nobreakspace", KEY_nobreakspace),
    ("NoSymbol", KEY_NoSymbol),
    ("notapproxeq", KEY_notapproxeq),
    ("notelementof", KEY_notelementof),
    ("notequal", KEY_notequal),
    ("notidentical", KEY_notidentical),
    ("notsign", KEY_notsign),
    ("Ntilde", KEY_Ntilde),
    ("ntilde", KEY_ntilde),
    ("Num_Lock", KEY_Num_Lock),
    ("numbersign", KEY_numbersign),
    ("numerosign", KEY_numerosign),
    ("O", KEY_O),
    ("o", KEY_o),
    ("Oacute", KEY_Oacute),
    ("oacute", KEY_oacute),
    ("Obarred", KEY_Obarred),
    ("obarred", KEY_obarred),
    ("Obelowdot", KEY_Obelowdot),
    ("obelowdot", KEY_obelowdot),
    ("Ocaron", KEY_Ocaron),
    ("ocaron", KEY_ocaron),
    ("Ocircumflex", KEY_Ocircumflex),
    ("ocircumflex", KEY_ocircumflex),
    ("Ocircumflexacute", KEY_Ocircumflexacute),
    ("ocircumflexacute", KEY_ocircumflexacute),
    ("Ocircumflexbelowdot", KEY_Ocircumflexbelowdot),
    ("ocircumflexbelowdot", KEY_ocircumflexbelowdot),
    ("Ocircumflexgrave", KEY_Ocircumflexgrave),
    ("ocircumflexgrave", KEY_ocircumflexgrave),
    ("Ocircumflexhook", KEY_Ocircumflexhook),
    ("ocircumflexhook", KEY_ocircumflexhook),
    ("Ocircumflextilde", KEY_Ocircumflextilde),
    ("ocircumflextilde", KEY_ocircumflextilde),
    ("Odiaeresis", KEY_Odiaeresis),
    ("odiaeresis", KEY_odiaeresis),
    ("Odoubleacute", KEY_Odoubleacute),
    ("odoubleacute", KEY_odoubleacute),
    ("OE", KEY_OE),
    ("oe", KEY_oe),
    ("ogonek", KEY_ogonek),
    ("Ograve", KEY_Ograve),
    ("ograve", KEY_ograve),
    ("Ohook", KEY_Ohook),
    ("ohook", KEY_ohook),
    ("Ohorn", KEY_Ohorn),
    ("ohorn", KEY_ohorn),
    ("Ohornacute", KEY_Ohornacute),
    ("ohornacute", KEY_ohornacute),
    ("Ohornbelowdot", KEY_Ohornbelowdot),
    ("ohornbelowdot", KEY_ohornbelowdot),
    ("Ohorngrave", KEY_Ohorngrave),
    ("ohorngrave", KEY_ohorngrave),
    ("Ohornhook", KEY_Ohornhook),
    ("ohornhook", KEY_ohornhook),
    ("Ohorntilde", KEY_Ohorntilde),
    ("ohorntilde", KEY_ohorntilde),
    ("Omacron", KEY_Omacron),
    ("omacron", KEY_omacron),
    ("oneeighth", KEY_oneeighth),
    ("onefifth", KEY_onefifth),
    ("onehalf", KEY_onehalf),
    ("onequarter", KEY_onequarter),
    ("onesixth", KEY_onesixth),
    ("onesubscript", KEY_onesubscript),
    ("onesuperior", KEY_onesuperior),
    ("onethird", KEY_onethird),
    ("Ooblique", KEY_Ooblique),
    ("ooblique", KEY_ooblique),
    ("openrectbullet", KEY_openrectbullet),
    ("openstar", KEY_openstar),
    ("opentribulletdown", KEY_opentribulletdown),
    ("opentribulletup", KEY_opentribulletup),
    ("ordfeminine", KEY_ordfeminine),
    ("ordmasculine", KEY_ordmasculine),
    ("osfActivate", KEY_osfActivate),
    ("osfAddMode", KEY_osfAddMode),
    ("osfBackSpace", KEY_osfBackSpace),
    ("osfBackTab", KEY_osfBackTab),
    ("osfBeginData", KEY_osfBeginData),
    ("osfBeginLine", KEY_osfBeginLine),
    ("osfCancel", KEY_osfCancel),
    ("osfClear", KEY_osfClear),
    ("osfCopy", KEY_osfCopy),
    ("osfCut", KEY_osfCut),
    ("osfDelete", KEY_osfDelete),
    ("osfDeselectAll", KEY_osfDeselectAll),
    ("osfDown", KEY_osfDown),
    ("osfEndData", KEY_osfEndData),
    ("osfEndLine", KEY_osfEndLine),
    ("osfEscape", KEY_osfEscape),
    ("osfExtend", KEY_osfExtend),
    ("osfHelp", KEY_osfHelp),
    ("osfInsert", KEY_osfInsert),
    ("osfLeft", KEY_osfLeft),
    ("osfMenu", KEY_osfMenu),
    ("osfMenuBar", KEY_osfMenuBar),
    ("osfNextField", KEY_osfNextField),
    ("osfNextMenu", KEY_osfNextMenu),
    ("osfPageDown", KEY_osfPageDown),
    ("osfPageLeft", KEY_osfPageLeft),
    ("osfPageRight", KEY_osfPageRight),
    ("osfPageUp", KEY_osfPageUp),
    ("osfPaste", KEY_osfPaste),
    ("osfPrevField", KEY_osfPrevField),
    ("osfPrevMenu", KEY_osfPrevMenu),
    ("osfPrimaryPaste", KEY_osfPrimaryPaste),
    ("osfQuickPaste", KEY_osfQuickPaste),
    ("osfReselect", KEY_osfReselect),
    ("osfRestore", KEY_osfRestore),
    ("osfRight", KEY_osfRight),
    ("osfSelect", KEY_osfSelect),
    ("osfSelectAll", KEY_osfSelectAll),
    ("osfUndo", KEY_osfUndo),
    ("osfUp", KEY_osfUp),
    ("Oslash", KEY_Oslash),
    ("oslash", KEY_oslash),
    ("Otilde", KEY_Otilde),
    ("otilde", KEY_otilde),
    ("overbar", KEY_overbar),
    ("Overlay1_Enable", KEY_Overlay1_Enable),
    ("Overlay2_Enable", KEY_Overlay2_Enable),
    ("overline", KEY_overline),
    ("P", KEY_P),
    ("p", KEY_p),
    ("Pabovedot", KEY_Pabovedot),
    ("pabovedot", KEY_pabovedot),
    ("Page_Down", KEY_Page_Down),
    ("Page_Up", KEY_Page_Up),
    ("paragraph", KEY_paragraph),
    ("parenleft", KEY_parenleft),
    ("parenright", KEY_parenright),
    ("partdifferential", KEY_partdifferential),
    ("partialderivative", KEY_partialderivative),
    ("Pause", KEY_Pause),
    ("percent", KEY_percent),
    ("period", KEY_period),
    ("periodcentered", KEY_periodcentered),
    ("permille", KEY_permille),
    ("PesetaSign", KEY_PesetaSign),
    ("phonographcopyright", KEY_phonographcopyright),
    ("plus", KEY_plus),
    ("plusminus", KEY_plusminus),
    ("Pointer_Accelerate", KEY_Pointer_Accelerate),
    ("Pointer_Button1", KEY_Pointer_Button1),
    ("Pointer_Button2", KEY_Pointer_Button2),
    ("Pointer_Button3", KEY_Pointer_Button3),
    ("Pointer_Button4", KEY_Pointer_Button4),
    ("Pointer_Button5", KEY_Pointer_Button5),
    ("Pointer_Button_Dflt", KEY_Pointer_Button_Dflt),
    ("Pointer_DblClick1", KEY_Pointer_DblClick1),
    ("Pointer_DblClick2", KEY_Pointer_DblClick2),
    ("Pointer_DblClick3", KEY_Pointer_DblClick3),
    ("Pointer_DblClick4", KEY_Pointer_DblClick4),
    ("Pointer_DblClick5", KEY_Pointer_DblClick5),
    ("Pointer_DblClick_Dflt", KEY_Pointer_DblClick_Dflt),
    ("Pointer_DfltBtnNext", KEY_Pointer_DfltBtnNext),
    ("Pointer_DfltBtnPrev", KEY_Pointer_DfltBtnPrev),
    ("Pointer_Down", KEY_Pointer_Down),
    ("Pointer_DownLeft", KEY_Pointer_DownLeft),
    ("Pointer_DownRight", KEY_Pointer_DownRight),
    ("Pointer_Drag1", KEY_Pointer_Drag1),
    ("Pointer_Drag2", KEY_Pointer_Drag2),
    ("Pointer_Drag3", KEY_Pointer_Drag3),
    ("Pointer_Drag4", KEY_Pointer_Drag4),
    ("Pointer_Drag5", KEY_Pointer_Drag5),
    ("Pointer_Drag_Dflt", KEY_Pointer_Drag_Dflt),
    ("Pointer_EnableKeys", KEY_Pointer_EnableKeys),
    ("Pointer_Left", KEY_Pointer_Left),
    ("Pointer_Right", KEY_Pointer_Right),
    ("Pointer_Up", KEY_Pointer_Up),
    ("Pointer_UpLeft", KEY_Pointer_UpLeft),
    ("Pointer_UpRight", KEY_Pointer_UpRight),
    ("prescription", KEY_prescription),
    ("Prev_Virtual_Screen", KEY_Prev_Virtual_Screen),
    ("PreviousCandidate", KEY_PreviousCandidate),
    ("Print", KEY_Print),
    ("Prior", KEY_Prior),
    ("prolongedsound", KEY_prolongedsound),
    ("punctspace", KEY_punctspace),
    ("Q", KEY_Q),
    ("q", KEY_q),
    ("quad", KEY_quad),
    ("question", KEY_question),
    ("questiondown", KEY_questiondown),
    ("quotedbl", KEY_quotedbl),
    ("quoteleft", KEY_quoteleft),
    ("quoteright", KEY_quoteright),
    ("R", KEY_R),
    ("r", KEY_r),
    ("R1", KEY_R1),
    ("R10", KEY_R10),
    ("R11", KEY_R11),
    ("R12", KEY_R12),
    ("R13", KEY_R13),
    ("R14", KEY_R14),
    ("R15", KEY_R15),
    ("R2", KEY_R2),
    ("R3", KEY_R3),
    ("R4", KEY_R4),
    ("R5", KEY_R5),
    ("R6", KEY_R6),
    ("R7", KEY_R7),
    ("R8", KEY_R8),
    ("R9", KEY_R9),
    ("Racute", KEY_Racute),
    ("racute", KEY_racute),
    ("radical", KEY_radical),
    ("Rcaron", KEY_Rcaron),
    ("rcaron", KEY_rcaron),
    ("Rcedilla", KEY_Rcedilla),
    ("rcedilla", KEY_rcedilla),
    ("Redo", KEY_Redo),
    ("registered", KEY_registered),
    ("RepeatKeys_Enable", KEY_RepeatKeys_Enable),
    ("Reset", KEY_Reset),
    ("Return", KEY_Return),
    ("Right", KEY_Right),
    ("rightanglebracket", KEY_rightanglebracket),
    ("rightarrow", KEY_rightarrow),
    ("rightcaret", KEY_rightcaret),
    ("rightdoublequotemark", KEY_rightdoublequotemark),
    ("rightmiddlecurlybrace", KEY_rightmiddlecurlybrace),
    ("rightmiddlesummation", KEY_rightmiddlesummation),
    ("rightopentriangle", KEY_rightopentriangle),
    ("rightpointer", KEY_rightpointer),
    ("rightshoe", KEY_rightshoe),
    ("rightsinglequotemark", KEY_rightsinglequotemark),
    ("rightt", KEY_rightt),
    ("righttack", KEY_righttack),
    ("Romaji", KEY_Romaji),
    ("RupeeSign", KEY_RupeeSign),
    ("S", KEY_S),
    ("s", KEY_s),
    ("Sabovedot", KEY_Sabovedot),
    ("sabovedot", KEY_sabovedot),
    ("Sacute", KEY_Sacute),
    ("sacute", KEY_sacute),
    ("Scaron", KEY_Scaron),
    ("scaron", KEY_scaron),
    ("Scedilla", KEY_Scedilla),
    ("scedilla", KEY_scedilla),
    ("SCHWA", KEY_SCHWA),
    ("schwa", KEY_schwa),
    ("Scircumflex", KEY_Scircumflex),
    ("scircumflex", KEY_scircumflex),
    ("script_switch", KEY_script_switch),
    ("Scroll_Lock", KEY_Scroll_Lock),
    ("seconds", KEY_seconds),
    ("section", KEY_section),
    ("Select", KEY_Select),
    ("semicolon", KEY_semicolon),
    ("semivoicedsound", KEY_semivoicedsound),
    ("Serbian_DJE", KEY_Serbian_DJE),
    ("Serbian_dje", KEY_Serbian_dje),
    ("Serbian_DZE", KEY_Serbian_DZE),
    ("Serbian_dze", KEY_Serbian_dze),
    ("Serbian_JE", KEY_Serbian_JE),
    ("Serbian_je", KEY_Serbian_je),
    ("Serbian_LJE", KEY_Serbian_LJE),
    ("Serbian_lje", KEY_Serbian_lje),
    ("Serbian_NJE", KEY_Serbian_NJE),
    ("Serbian_nje", KEY_Serbian_nje),
    ("Serbian_TSHE", KEY_Serbian_TSHE),
    ("Serbian_tshe", KEY_Serbian_tshe),
    ("seveneighths", KEY_seveneighths),
    ("sevensubscript", KEY_sevensubscript),
    ("sevensuperior", KEY_sevensuperior),
    ("Shift_L", KEY_Shift_L),
    ("Shift_Lock", KEY_Shift_Lock),
    ("Shift_R", KEY_Shift_R),
    ("signaturemark", KEY_signaturemark),
    ("signifblank", KEY_signifblank),
    ("similarequal", KEY_similarequal),
    ("SingleCandidate", KEY_SingleCandidate),
    ("singlelowquotemark", KEY_singlelowquotemark),
    ("Sinh_a", KEY_Sinh_a),
    ("Sinh_aa", KEY_Sinh_aa),
    ("Sinh_aa2", KEY_Sinh_aa2),
    ("Sinh_ae", KEY_Sinh_ae),
    ("Sinh_ae2", KEY_Sinh_ae2),
    ("Sinh_aee", KEY_Sinh_aee),
    ("Sinh_aee2", KEY_Sinh_aee2),
    ("Sinh_ai", KEY_Sinh_ai),
    ("Sinh_ai2", KEY_Sinh_ai2),
    ("Sinh_al", KEY_Sinh_al),
    ("Sinh_au", KEY_Sinh_au),
    ("Sinh_au2", KEY_Sinh_au2),
    ("Sinh_ba", KEY_Sinh_ba),
    ("Sinh_bha", KEY_Sinh_bha),
    ("Sinh_ca", KEY_Sinh_ca),
    ("Sinh_cha", KEY_Sinh_cha),
    ("Sinh_dda", KEY_Sinh_dda),
    ("Sinh_ddha", KEY_Sinh_ddha),
    ("Sinh_dha", KEY_Sinh_dha),
    ("Sinh_dhha", KEY_Sinh_dhha),
    ("Sinh_e", KEY_Sinh_e),
    ("Sinh_e2", KEY_Sinh_e2),
    ("Sinh_ee", KEY_Sinh_ee),
    ("Sinh_ee2", KEY_Sinh_ee2),
    ("Sinh_fa", KEY_Sinh_fa),
    ("Sinh_ga", KEY_Sinh_ga),
    ("Sinh_gha", KEY_Sinh_gha),
    ("Sinh_h2", KEY_Sinh_h2),
    ("Sinh_ha", KEY_Sinh_ha),
    ("Sinh_i", KEY_Sinh_i),
    ("Sinh_i2", KEY_Sinh_i2),
    ("Sinh_ii", KEY_Sinh_ii),
    ("Sinh_ii2", KEY_Sinh_ii2),
    ("Sinh_ja", KEY_Sinh_ja),
    ("Sinh_jha", KEY_Sinh_jha),
    ("Sinh_jnya", KEY_Sinh_jnya),
    ("Sinh_ka", KEY_Sinh_ka),
    ("Sinh_kha", KEY_Sinh_kha),
    ("Sinh_kunddaliya", KEY_Sinh_kunddaliya),
    ("Sinh_la", KEY_Sinh_la),
    ("Sinh_lla", KEY_Sinh_lla),
    ("Sinh_lu", KEY_Sinh_lu),
    ("Sinh_lu2", KEY_Sinh_lu2),
    ("Sinh_luu", KEY_Sinh_luu),
    ("Sinh_luu2", KEY_Sinh_luu2),
    ("Sinh_ma", KEY_Sinh_ma),
    ("Sinh_mba", KEY_Sinh_mba),
    ("Sinh_na", KEY_Sinh_na),
    ("Sinh_ndda", KEY_Sinh_ndda),
    ("Sinh_ndha", KEY_Sinh_ndha),
    ("Sinh_ng", KEY_Sinh_ng),
    ("Sinh_ng2", KEY_Sinh_ng2),
    ("Sinh_nga", KEY_Sinh_nga),
    ("Sinh_nja", KEY_Sinh_nja),
    ("Sinh_nna", KEY_Sinh_nna),
    ("Sinh_nya", KEY_Sinh_nya),
    ("Sinh_o", KEY_Sinh_o),
    ("Sinh_o2", KEY_Sinh_o2),
    ("Sinh_oo", KEY_Sinh_oo),
    ("Sinh_oo2", KEY_Sinh_oo2),
    ("Sinh_pa", KEY_Sinh_pa),
    ("Sinh_pha", KEY_Sinh_pha),
    ("Sinh_ra", KEY_Sinh_ra),
    ("Sinh_ri", KEY_Sinh_ri),
    ("Sinh_rii", KEY_Sinh_rii),
    ("Sinh_ru2", KEY_Sinh_ru2),
    ("Sinh_ruu2", KEY_Sinh_ruu2),
    ("Sinh_sa", KEY_Sinh_sa),
    ("Sinh_sha", KEY_Sinh_sha),
    ("Sinh_ssha", KEY_Sinh_ssha),
    ("Sinh_tha", KEY_Sinh_tha),
    ("Sinh_thha", KEY_Sinh_thha),
    ("Sinh_tta", KEY_Sinh_tta),
    ("Sinh_ttha", KEY_Sinh_ttha),
    ("Sinh_u", KEY_Sinh_u),
    ("Sinh_u2", KEY_Sinh_u2),
    ("Sinh_uu", KEY_Sinh_uu),
    ("Sinh_uu2", KEY_Sinh_uu2),
    ("Sinh_va", KEY_Sinh_va),
    ("Sinh_ya", KEY_Sinh_ya),
    ("sixsubscript", KEY_sixsubscript),
    ("sixsuperior", KEY_sixsuperior),
    ("slash", KEY_slash),
    ("SlowKeys_Enable", KEY_SlowKeys_Enable),
    ("soliddiamond", KEY_soliddiamond),
    ("space", KEY_space),
    ("squareroot", KEY_squareroot),
    ("ssharp", KEY_ssharp),
    ("sterling", KEY_sterling),
    ("StickyKeys_Enable", KEY_StickyKeys_Enable),
    ("stricteq", KEY_stricteq),
    ("SunAgain", KEY_SunAgain),
    ("SunAltGraph", KEY_SunAltGraph),
    ("SunAudioLowerVolume", KEY_SunAudioLowerVolume),
    ("SunAudioMute", KEY_SunAudioMute),
    ("SunAudioRaiseVolume", KEY_SunAudioRaiseVolume),
    ("SunCompose", KEY_SunCompose),
    ("SunCopy", KEY_SunCopy),
    ("SunCut", KEY_SunCut),
    ("SunF36", KEY_SunF36),
    ("SunF37", KEY_SunF37),
    ("SunFA_Acute", KEY_SunFA_Acute),
    ("SunFA_Cedilla", KEY_SunFA_Cedilla),
    ("SunFA_Circum", KEY_SunFA_Circum),
    ("SunFA_Diaeresis", KEY_SunFA_Diaeresis),
    ("SunFA_Grave", KEY_SunFA_Grave),
    ("SunFA_Tilde", KEY_SunFA_Tilde),
    ("SunFind", KEY_SunFind),
    ("SunFront", KEY_SunFront),
    ("SunOpen", KEY_SunOpen),
    ("SunPageDown", KEY_SunPageDown),
    ("SunPageUp", KEY_SunPageUp),
    ("SunPaste", KEY_SunPaste),
    ("SunPowerSwitch", KEY_SunPowerSwitch),
    ("SunPowerSwitchShift", KEY_SunPowerSwitchShift),
    ("SunPrint_Screen", KEY_SunPrint_Screen),
    ("SunProps", KEY_SunProps),
    ("SunStop", KEY_SunStop),
    ("SunSys_Req", KEY_SunSys_Req),
    ("SunUndo", KEY_SunUndo),
    ("SunVideoDegauss", KEY_SunVideoDegauss),
    ("SunVideoLowerBrightness", KEY_SunVideoLowerBrightness),
    ("SunVideoRaiseBrightness", KEY_SunVideoRaiseBrightness),
    ("Super_L", KEY_Super_L),
    ("Super_R", KEY_Super_R),
    ("Sys_Req", KEY_Sys_Req),
    ("System", KEY_System),
    ("T", KEY_T),
    ("t", KEY_t),
    ("Tab", KEY_Tab),
    ("Tabovedot", KEY_Tabovedot),
    ("tabovedot", KEY_tabovedot),
    ("Tcaron", KEY_Tcaron),
    ("tcaron", KEY_tcaron),
    ("Tcedilla", KEY_Tcedilla),
    ("tcedilla", KEY_tcedilla),
    ("telephone", KEY_telephone),
    ("telephonerecorder", KEY_telephonerecorder),
    ("Terminate_Server", KEY_Terminate_Server),
    ("Thai_baht", KEY_Thai_baht),
    ("Thai_bobaimai", KEY_Thai_bobaimai),
    ("Thai_chochan", KEY_Thai_chochan),
    ("Thai_chochang", KEY_Thai_chochang),
    ("Thai_choching", KEY_Thai_choching),
    ("Thai_chochoe", KEY_Thai_chochoe),
    ("Thai_dochada", KEY_Thai_dochada),
    ("Thai_dodek", KEY_Thai_dodek),
    ("Thai_fofa", KEY_Thai_fofa),
    ("Thai_fofan", KEY_Thai_fofan),
    ("Thai_hohip", KEY_Thai_hohip),
    ("Thai_honokhuk", KEY_Thai_honokhuk),
    ("Thai_khokhai", KEY_Thai_khokhai),
    ("Thai_khokhon", KEY_Thai_khokhon),
    ("Thai_khokhuat", KEY_Thai_khokhuat),
    ("Thai_khokhwai", KEY_Thai_khokhwai),
    ("Thai_khorakhang", KEY_Thai_khorakhang),
    ("Thai_kokai", KEY_Thai_kokai),
    ("Thai_lakkhangyao", KEY_Thai_lakkhangyao),
    ("Thai_lekchet", KEY_Thai_lekchet),
    ("Thai_lekha", KEY_Thai_lekha),
    ("Thai_lekhok", KEY_Thai_lekhok),
    ("Thai_lekkao", KEY_Thai_lekkao),
    ("Thai_leknung", KEY_Thai_leknung),
    ("Thai_lekpaet", KEY_Thai_lekpaet),
    ("Thai_leksam", KEY_Thai_leksam),
    ("Thai_leksi", KEY_Thai_leksi),
    ("Thai_leksong", KEY_Thai_leksong),
    ("Thai_leksun", KEY_Thai_leksun),
    ("Thai_lochula", KEY_Thai_lochula),
    ("Thai_loling", KEY_Thai_loling),
    ("Thai_lu", KEY_Thai_lu),
    ("Thai_maichattawa", KEY_Thai_maichattawa),
    ("Thai_maiek", KEY_Thai_maiek),
    ("Thai_maihanakat", KEY_Thai_maihanakat),
    ("Thai_maihanakat_maitho", KEY_Thai_maihanakat_maitho),
    ("Thai_maitaikhu", KEY_Thai_maitaikhu),
    ("Thai_maitho", KEY_Thai_maitho),
    ("Thai_maitri", KEY_Thai_maitri),
    ("Thai_maiyamok", KEY_Thai_maiyamok),
    ("Thai_moma", KEY_Thai_moma),
    ("Thai_ngongu", KEY_Thai_ngongu),
    ("Thai_nikhahit", KEY_Thai_nikhahit),
    ("Thai_nonen", KEY_Thai_nonen),
    ("Thai_nonu", KEY_Thai_nonu),
    ("Thai_oang", KEY_Thai_oang),
    ("Thai_paiyannoi", KEY_Thai_paiyannoi),
    ("Thai_phinthu", KEY_Thai_phinthu),
    ("Thai_phophan", KEY_Thai_phophan),
    ("Thai_phophung", KEY_Thai_phophung),
    ("Thai_phosamphao", KEY_Thai_phosamphao),
    ("Thai_popla", KEY_Thai_popla),
    ("Thai_rorua", KEY_Thai_rorua),
    ("Thai_ru", KEY_Thai_ru),
    ("Thai_saraa", KEY_Thai_saraa),
    ("Thai_saraaa", KEY_Thai_saraaa),
    ("Thai_saraae", KEY_Thai_saraae),
    ("Thai_saraaimaimalai", KEY_Thai_saraaimaimalai),
    ("Thai_saraaimaimuan", KEY_Thai_saraaimaimuan),
    ("Thai_saraam", KEY_Thai_saraam),
    ("Thai_sarae", KEY_Thai_sarae),
    ("Thai_sarai", KEY_Thai_sarai),
    ("Thai_saraii", KEY_Thai_saraii),
    ("Thai_sarao", KEY_Thai_sarao),
    ("Thai_sarau", KEY_Thai_sarau),
    ("Thai_saraue", KEY_Thai_saraue),
    ("Thai_sarauee", KEY_Thai_sarauee),
    ("Thai_sarauu", KEY_Thai_sarauu),
    ("Thai_sorusi", KEY_Thai_sorusi),
    ("Thai_sosala", KEY_Thai_sosala),
    ("Thai_soso", KEY_Thai_soso),
    ("Thai_sosua", KEY_Thai_sosua),
    ("Thai_thanthakhat", KEY_Thai_thanthakhat),
    ("Thai_thonangmontho", KEY_Thai_thonangmontho),
    ("Thai_thophuthao", KEY_Thai_thophuthao),
    ("Thai_thothahan", KEY_Thai_thothahan),
    ("Thai_thothan", KEY_Thai_thothan),
    ("Thai_thothong", KEY_Thai_thothong),
    ("Thai_thothung", KEY_Thai_thothung),
    ("Thai_topatak", KEY_Thai_topatak),
    ("Thai_totao", KEY_Thai_totao),
    ("Thai_wowaen", KEY_Thai_wowaen),
    ("Thai_yoyak", KEY_Thai_yoyak),
    ("Thai_yoying", KEY_Thai_yoying),
    ("therefore", KEY_therefore),
    ("thinspace", KEY_thinspace),
    ("THORN", KEY_THORN),
    ("Thorn", KEY_Thorn),
    ("thorn", KEY_thorn),
    ("threeeighths", KEY_threeeighths),
    ("threefifths", KEY_threefifths),
    ("threequarters", KEY_threequarters),
    ("threesubscript", KEY_threesubscript),
    ("threesuperior", KEY_threesuperior),
    ("tintegral", KEY_tintegral),
    ("topintegral", KEY_topintegral),
    ("topleftparens", KEY_topleftparens),
    ("topleftradical", KEY_topleftradical),
    ("topleftsqbracket", KEY_topleftsqbracket),
    ("topleftsummation", KEY_topleftsummation),
    ("toprightparens", KEY_toprightparens),
    ("toprightsqbracket", KEY_toprightsqbracket),
    ("toprightsummation", KEY_toprightsummation),
    ("topt", KEY_topt),
    ("topvertsummationconnector", KEY_topvertsummationconnector),
    ("Touroku", KEY_Touroku),
    ("trademark", KEY_trademark),
    ("trademarkincircle", KEY_trademarkincircle),
    ("Tslash", KEY_Tslash),
    ("tslash", KEY_tslash),
    ("twofifths", KEY_twofifths),
    ("twosubscript", KEY_twosubscript),
    ("twosuperior", KEY_twosuperior),
    ("twothirds", KEY_twothirds),
    ("U", KEY_U),
    ("u", KEY_u),
    ("Uacute", KEY_Uacute),
    ("uacute", KEY_uacute),
    ("Ubelowdot", KEY_Ubelowdot),
    ("ubelowdot", KEY_ubelowdot),
    ("Ubreve", KEY_Ubreve),
    ("ubreve", KEY_ubreve),
    ("Ucircumflex", KEY_Ucircumflex),
    ("ucircumflex", KEY_ucircumflex),
    ("Udiaeresis", KEY_Udiaeresis),
    ("udiaeresis", KEY_udiaeresis),
    ("Udoubleacute", KEY_Udoubleacute),
    ("udoubleacute", KEY_udoubleacute),
    ("Ugrave", KEY_Ugrave),
    ("ugrave", KEY_ugrave),
    ("Uhook", KEY_Uhook),
    ("uhook", KEY_uhook),
    ("Uhorn", KEY_Uhorn),
    ("uhorn", KEY_uhorn),
    ("Uhornacute", KEY_Uhornacute),
    ("uhornacute", KEY_uhornacute),
    ("Uhornbelowdot", KEY_Uhornbelowdot),
    ("uhornbelowdot", KEY_uhornbelowdot),
    ("Uhorngrave", KEY_Uhorngrave),
    ("uhorngrave", KEY_uhorngrave),
    ("Uhornhook", KEY_Uhornhook),
    ("uhornhook", KEY_uhornhook),
    ("Uhorntilde", KEY_Uhorntilde),
    ("uhorntilde", KEY_uhorntilde),
    ("Ukrainian_GHE_WITH_UPTURN", KEY_Ukrainian_GHE_WITH_UPTURN),
    ("Ukrainian_ghe_with_upturn", KEY_Ukrainian_ghe_with_upturn),
    ("Ukrainian_I", KEY_Ukrainian_I),
    ("Ukrainian_i", KEY_Ukrainian_i),
    ("Ukrainian_IE", KEY_Ukrainian_IE),
    ("Ukrainian_ie", KEY_Ukrainian_ie),
    ("Ukrainian_YI", KEY_Ukrainian_YI),
    ("Ukrainian_yi", KEY_Ukrainian_yi),
    ("Ukranian_I", KEY_Ukranian_I),
    ("Ukranian_i", KEY_Ukranian_i),
    ("Ukranian_JE", KEY_Ukranian_JE),
    ("Ukranian_je", KEY_Ukranian_je),
    ("Ukranian_YI", KEY_Ukranian_YI),
    ("Ukranian_yi", KEY_Ukranian_yi),
    ("Umacron", KEY_Umacron),
    ("umacron", KEY_umacron),
    ("underbar", KEY_underbar),
    ("underscore", KEY_underscore),
    ("Undo", KEY_Undo),
    ("union", KEY_union),
    ("Uogonek", KEY_Uogonek),
    ("uogonek", KEY_uogonek),
    ("Up", KEY_Up),
    ("uparrow", KEY_uparrow),
    ("upcaret", KEY_upcaret),
    ("upleftcorner", KEY_upleftcorner),
    ("uprightcorner", KEY_uprightcorner),
    ("upshoe", KEY_upshoe),
    ("upstile", KEY_upstile),
    ("uptack", KEY_uptack),
    ("Uring", KEY_Uring),
    ("uring", KEY_uring),
    ("User", KEY_User),
    ("Utilde", KEY_Utilde),
    ("utilde", KEY_utilde),
    ("V", KEY_V),
    ("v", KEY_v),
    ("variation", KEY_variation),
    ("vertbar", KEY_vertbar),
    ("vertconnector", KEY_vertconnector),
    ("voicedsound", KEY_voicedsound),
    ("VoidSymbol", KEY_VoidSymbol),
    ("vt", KEY_vt),
    ("W", KEY_W),
    ("w", KEY_w),
    ("Wacute", KEY_Wacute),
    ("wacute", KEY_wacute),
    ("Wcircumflex", KEY_Wcircumflex),
    ("wcircumflex", KEY_wcircumflex),
    ("Wdiaeresis", KEY_Wdiaeresis),
    ("wdiaeresis", KEY_wdiaeresis),
    ("Wgrave", KEY_Wgrave),
    ("wgrave", KEY_wgrave),
    ("WonSign", KEY_WonSign),
    ("X", KEY_X),
    ("x", KEY_x),
    ("Xabovedot", KEY_Xabovedot),
    ("xabovedot", KEY_xabovedot),
    ("XF8610ChannelsDown", KEY_XF8610ChannelsDown),
    ("XF8610ChannelsUp", KEY_XF8610ChannelsUp),
    ("XF863DMode", KEY_XF863DMode),
    ("XF86AddFavorite", KEY_XF86AddFavorite),
    ("XF86Addressbook", KEY_XF86Addressbook),
    ("XF86ALSToggle", KEY_XF86ALSToggle),
    ("XF86ApplicationLeft", KEY_XF86ApplicationLeft),
    ("XF86ApplicationRight", KEY_XF86ApplicationRight),
    ("XF86AppSelect", KEY_XF86AppSelect),
    ("XF86AspectRatio", KEY_XF86AspectRatio),
    ("XF86Assistant", KEY_XF86Assistant),
    ("XF86AttendantOff", KEY_XF86AttendantOff),
    ("XF86AttendantOn", KEY_XF86AttendantOn),
    ("XF86AttendantToggle", KEY_XF86AttendantToggle),
    ("XF86Audio", KEY_XF86Audio),
    ("XF86AudioCycleTrack", KEY_XF86AudioCycleTrack),
    ("XF86AudioDesc", KEY_XF86AudioDesc),
    ("XF86AudioForward", KEY_XF86AudioForward),
    ("XF86AudioLowerVolume", KEY_XF86AudioLowerVolume),
    ("XF86AudioMedia", KEY_XF86AudioMedia),
    ("XF86AudioMicMute", KEY_XF86AudioMicMute),
    ("XF86AudioMute", KEY_XF86AudioMute),
    ("XF86AudioNext", KEY_XF86AudioNext),
    ("XF86AudioPause", KEY_XF86AudioPause),
    ("XF86AudioPlay", KEY_XF86AudioPlay),
    ("XF86AudioPreset", KEY_XF86AudioPreset),
    ("XF86AudioPrev", KEY_XF86AudioPrev),
    ("XF86AudioRaiseVolume", KEY_XF86AudioRaiseVolume),
    ("XF86AudioRandomPlay", KEY_XF86AudioRandomPlay),
    ("XF86AudioRecord", KEY_XF86AudioRecord),
    ("XF86AudioRepeat", KEY_XF86AudioRepeat),
    ("XF86AudioRewind", KEY_XF86AudioRewind),
    ("XF86AudioStop", KEY_XF86AudioStop),
    ("XF86AutopilotEngageToggle", KEY_XF86AutopilotEngageToggle),
    ("XF86Away", KEY_XF86Away),
    ("XF86Back", KEY_XF86Back),
    ("XF86BackForward", KEY_XF86BackForward),
    ("XF86Battery", KEY_XF86Battery),
    ("XF86Blue", KEY_XF86Blue),
    ("XF86Bluetooth", KEY_XF86Bluetooth),
    ("XF86Book", KEY_XF86Book),
    ("XF86Break", KEY_XF86Break),
    ("XF86BrightnessAdjust", KEY_XF86BrightnessAdjust),
    ("XF86BrightnessAuto", KEY_XF86BrightnessAuto),
    ("XF86BrightnessMax", KEY_XF86BrightnessMax),
    ("XF86BrightnessMin", KEY_XF86BrightnessMin),
    ("XF86Buttonconfig", KEY_XF86Buttonconfig),
    ("XF86Calculater", KEY_XF86Calculater),
    ("XF86Calculator", KEY_XF86Calculator),
    ("XF86Calendar", KEY_XF86Calendar),
    ("XF86CameraAccessDisable", KEY_XF86CameraAccessDisable),
    ("XF86CameraAccessEnable", KEY_XF86CameraAccessEnable),
    ("XF86CameraAccessToggle", KEY_XF86CameraAccessToggle),
    ("XF86CameraDown", KEY_XF86CameraDown),
    ("XF86CameraFocus", KEY_XF86CameraFocus),
    ("XF86CameraLeft", KEY_XF86CameraLeft),
    ("XF86CameraRight", KEY_XF86CameraRight),
    ("XF86CameraUp", KEY_XF86CameraUp),
    ("XF86CameraZoomIn", KEY_XF86CameraZoomIn),
    ("XF86CameraZoomOut", KEY_XF86CameraZoomOut),
    ("XF86CD", KEY_XF86CD),
    ("XF86ChannelDown", KEY_XF86ChannelDown),
    ("XF86ChannelUp", KEY_XF86ChannelUp),
    ("XF86Clear", KEY_XF86Clear),
    ("XF86ClearGrab", KEY_XF86ClearGrab),
    ("XF86ClearvuSonar", KEY_XF86ClearvuSonar),
    ("XF86Close", KEY_XF86Close),
    ("XF86Community", KEY_XF86Community),
    ("XF86ContextMenu", KEY_XF86ContextMenu),
    ("XF86ContrastAdjust", KEY_XF86ContrastAdjust),
    ("XF86ControlPanel", KEY_XF86ControlPanel),
    ("XF86Copy", KEY_XF86Copy),
    ("XF86Cut", KEY_XF86Cut),
    ("XF86CycleAngle", KEY_XF86CycleAngle),
    ("XF86Data", KEY_XF86Data),
    ("XF86Database", KEY_XF86Database),
    ("XF86Dictate", KEY_XF86Dictate),
    ("XF86Display", KEY_XF86Display),
    ("XF86DisplayOff", KEY_XF86DisplayOff),
    ("XF86DisplayToggle", KEY_XF86DisplayToggle),
    ("XF86Documents", KEY_XF86Documents),
    ("XF86DOS", KEY_XF86DOS),
    ("XF86DualRangeRadar", KEY_XF86DualRangeRadar),
    ("XF86DVD", KEY_XF86DVD),
    ("XF86Editor", KEY_XF86Editor),
    ("XF86Eject", KEY_XF86Eject),
    ("XF86EmojiPicker", KEY_XF86EmojiPicker),
    ("XF86Excel", KEY_XF86Excel),
    ("XF86Explorer", KEY_XF86Explorer),
    ("XF86FastReverse", KEY_XF86FastReverse),
    ("XF86Favorites", KEY_XF86Favorites),
    ("XF86Finance", KEY_XF86Finance),
    ("XF86FishingChart", KEY_XF86FishingChart),
    ("XF86Fn", KEY_XF86Fn),
    ("XF86Fn_Esc", KEY_XF86Fn_Esc),
    ("XF86FnRightShift", KEY_XF86FnRightShift),
    ("XF86Forward", KEY_XF86Forward),
    ("XF86FrameBack", KEY_XF86FrameBack),
    ("XF86FrameForward", KEY_XF86FrameForward),
    ("XF86FullScreen", KEY_XF86FullScreen),
    ("XF86Game", KEY_XF86Game),
    ("XF86Go", KEY_XF86Go),
    ("XF86GraphicsEditor", KEY_XF86GraphicsEditor),
    ("XF86Green", KEY_XF86Green),
    ("XF86HangupPhone", KEY_XF86HangupPhone),
    ("XF86Hibernate", KEY_XF86Hibernate),
    ("XF86History", KEY_XF86History),
    ("XF86HomePage", KEY_XF86HomePage),
    ("XF86HotLinks", KEY_XF86HotLinks),
    ("XF86Images", KEY_XF86Images),
    ("XF86Info", KEY_XF86Info),
    ("XF86iTouch", KEY_XF86iTouch),
    ("XF86Journal", KEY_XF86Journal),
    ("XF86KbdBrightnessDown", KEY_XF86KbdBrightnessDown),
    ("XF86KbdBrightnessUp", KEY_XF86KbdBrightnessUp),
    ("XF86KbdInputAssistAccept", KEY_XF86KbdInputAssistAccept),
    ("XF86KbdInputAssistCancel", KEY_XF86KbdInputAssistCancel),
    ("XF86KbdInputAssistNext", KEY_XF86KbdInputAssistNext),
    (
        "XF86KbdInputAssistNextgroup",
        KEY_XF86KbdInputAssistNextgroup,
    ),
    ("XF86KbdInputAssistPrev", KEY_XF86KbdInputAssistPrev),
    (
        "XF86KbdInputAssistPrevgroup",
        KEY_XF86KbdInputAssistPrevgroup,
    ),
    ("XF86KbdLcdMenu1", KEY_XF86KbdLcdMenu1),
    ("XF86KbdLcdMenu2", KEY_XF86KbdLcdMenu2),
    ("XF86KbdLcdMenu3", KEY_XF86KbdLcdMenu3),
    ("XF86KbdLcdMenu4", KEY_XF86KbdLcdMenu4),
    ("XF86KbdLcdMenu5", KEY_XF86KbdLcdMenu5),
    ("XF86KbdLightOnOff", KEY_XF86KbdLightOnOff),
    ("XF86Keyboard", KEY_XF86Keyboard),
    ("XF86Launch0", KEY_XF86Launch0),
    ("XF86Launch1", KEY_XF86Launch1),
    ("XF86Launch2", KEY_XF86Launch2),
    ("XF86Launch3", KEY_XF86Launch3),
    ("XF86Launch4", KEY_XF86Launch4),
    ("XF86Launch5", KEY_XF86Launch5),
    ("XF86Launch6", KEY_XF86Launch6),
    ("XF86Launch7", KEY_XF86Launch7),
    ("XF86Launch8", KEY_XF86Launch8),
    ("XF86Launch9", KEY_XF86Launch9),
    ("XF86LaunchA", KEY_XF86LaunchA),
    ("XF86LaunchB", KEY_XF86LaunchB),
    ("XF86LaunchC", KEY_XF86LaunchC),
    ("XF86LaunchD", KEY_XF86LaunchD),
    ("XF86LaunchE", KEY_XF86LaunchE),
    ("XF86LaunchF", KEY_XF86LaunchF),
    ("XF86LeftDown", KEY_XF86LeftDown),
    ("XF86LeftUp", KEY_XF86LeftUp),
    ("XF86LightBulb", KEY_XF86LightBulb),
    ("XF86LightsToggle", KEY_XF86LightsToggle),
    ("XF86LogGrabInfo", KEY_XF86LogGrabInfo),
    ("XF86LogOff", KEY_XF86LogOff),
    ("XF86LogWindowTree", KEY_XF86LogWindowTree),
    ("XF86Macro1", KEY_XF86Macro1),
    ("XF86Macro10", KEY_XF86Macro10),
    ("XF86Macro11", KEY_XF86Macro11),
    ("XF86Macro12", KEY_XF86Macro12),
    ("XF86Macro13", KEY_XF86Macro13),
    ("XF86Macro14", KEY_XF86Macro14),
    ("XF86Macro15", KEY_XF86Macro15),
    ("XF86Macro16", KEY_XF86Macro16),
    ("XF86Macro17", KEY_XF86Macro17),
    ("XF86Macro18", KEY_XF86Macro18),
    ("XF86Macro19", KEY_XF86Macro19),
    ("XF86Macro2", KEY_XF86Macro2),
    ("XF86Macro20", KEY_XF86Macro20),
    ("XF86Macro21", KEY_XF86Macro21),
    ("XF86Macro22", KEY_XF86Macro22),
    ("XF86Macro23", KEY_XF86Macro23),
    ("XF86Macro24", KEY_XF86Macro24),
    ("XF86Macro25", KEY_XF86Macro25),
    ("XF86Macro26", KEY_XF86Macro26),
    ("XF86Macro27", KEY_XF86Macro27),
    ("XF86Macro28", KEY_XF86Macro28),
    ("XF86Macro29", KEY_XF86Macro29),
    ("XF86Macro3", KEY_XF86Macro3),
    ("XF86Macro30", KEY_XF86Macro30),
    ("XF86Macro4", KEY_XF86Macro4),
    ("XF86Macro5", KEY_XF86Macro5),
    ("XF86Macro6", KEY_XF86Macro6),
    ("XF86Macro7", KEY_XF86Macro7),
    ("XF86Macro8", KEY_XF86Macro8),
    ("XF86Macro9", KEY_XF86Macro9),
    ("XF86MacroPreset1", KEY_XF86MacroPreset1),
    ("XF86MacroPreset2", KEY_XF86MacroPreset2),
    ("XF86MacroPreset3", KEY_XF86MacroPreset3),
    ("XF86MacroPresetCycle", KEY_XF86MacroPresetCycle),
    ("XF86MacroRecordStart", KEY_XF86MacroRecordStart),
    ("XF86MacroRecordStop", KEY_XF86MacroRecordStop),
    ("XF86Mail", KEY_XF86Mail),
    ("XF86MailForward", KEY_XF86MailForward),
    ("XF86Market", KEY_XF86Market),
    ("XF86MarkWaypoint", KEY_XF86MarkWaypoint),
    ("XF86MediaRepeat", KEY_XF86MediaRepeat),
    ("XF86MediaTopMenu", KEY_XF86MediaTopMenu),
    ("XF86Meeting", KEY_XF86Meeting),
    ("XF86Memo", KEY_XF86Memo),
    ("XF86MenuKB", KEY_XF86MenuKB),
    ("XF86MenuPB", KEY_XF86MenuPB),
    ("XF86Messenger", KEY_XF86Messenger),
    ("XF86ModeLock", KEY_XF86ModeLock),
    ("XF86MonBrightnessCycle", KEY_XF86MonBrightnessCycle),
    ("XF86MonBrightnessDown", KEY_XF86MonBrightnessDown),
    ("XF86MonBrightnessUp", KEY_XF86MonBrightnessUp),
    ("XF86Music", KEY_XF86Music),
    ("XF86MyComputer", KEY_XF86MyComputer),
    ("XF86MySites", KEY_XF86MySites),
    ("XF86NavChart", KEY_XF86NavChart),
    ("XF86NavInfo", KEY_XF86NavInfo),
    ("XF86New", KEY_XF86New),
    ("XF86News", KEY_XF86News),
    ("XF86Next_VMode", KEY_XF86Next_VMode),
    ("XF86NextElement", KEY_XF86NextElement),
    ("XF86NextFavorite", KEY_XF86NextFavorite),
    ("XF86NotificationCenter", KEY_XF86NotificationCenter),
    ("XF86Numeric0", KEY_XF86Numeric0),
    ("XF86Numeric1", KEY_XF86Numeric1),
    ("XF86Numeric11", KEY_XF86Numeric11),
    ("XF86Numeric12", KEY_XF86Numeric12),
    ("XF86Numeric2", KEY_XF86Numeric2),
    ("XF86Numeric3", KEY_XF86Numeric3),
    ("XF86Numeric4", KEY_XF86Numeric4),
    ("XF86Numeric5", KEY_XF86Numeric5),
    ("XF86Numeric6", KEY_XF86Numeric6),
    ("XF86Numeric7", KEY_XF86Numeric7),
    ("XF86Numeric8", KEY_XF86Numeric8),
    ("XF86Numeric9", KEY_XF86Numeric9),
    ("XF86NumericA", KEY_XF86NumericA),
    ("XF86NumericB", KEY_XF86NumericB),
    ("XF86NumericC", KEY_XF86NumericC),
    ("XF86NumericD", KEY_XF86NumericD),
    ("XF86NumericPound", KEY_XF86NumericPound),
    ("XF86NumericStar", KEY_XF86NumericStar),
    ("XF86OfficeHome", KEY_XF86OfficeHome),
    ("XF86OnScreenKeyboard", KEY_XF86OnScreenKeyboard),
    ("XF86Open", KEY_XF86Open),
    ("XF86OpenURL", KEY_XF86OpenURL),
    ("XF86Option", KEY_XF86Option),
    ("XF86Paste", KEY_XF86Paste),
    ("XF86PauseRecord", KEY_XF86PauseRecord),
    ("XF86Phone", KEY_XF86Phone),
    ("XF86PickupPhone", KEY_XF86PickupPhone),
    ("XF86Pictures", KEY_XF86Pictures),
    ("XF86PowerDown", KEY_XF86PowerDown),
    ("XF86PowerOff", KEY_XF86PowerOff),
    ("XF86Presentation", KEY_XF86Presentation),
    ("XF86Prev_VMode", KEY_XF86Prev_VMode),
    ("XF86PreviousElement", KEY_XF86PreviousElement),
    ("XF86PrivacyScreenToggle", KEY_XF86PrivacyScreenToggle),
    ("XF86Q", KEY_XF86Q),
    ("XF86RadarOverlay", KEY_XF86RadarOverlay),
    ("XF86Red", KEY_XF86Red),
    ("XF86Refresh", KEY_XF86Refresh),
    ("XF86Reload", KEY_XF86Reload),
    ("XF86Reply", KEY_XF86Reply),
    ("XF86RFKill", KEY_XF86RFKill),
    ("XF86RightDown", KEY_XF86RightDown),
    ("XF86RightUp", KEY_XF86RightUp),
    ("XF86RockerDown", KEY_XF86RockerDown),
    ("XF86RockerEnter", KEY_XF86RockerEnter),
    ("XF86RockerUp", KEY_XF86RockerUp),
    ("XF86RootMenu", KEY_XF86RootMenu),
    ("XF86RotateWindows", KEY_XF86RotateWindows),
    ("XF86RotationKB", KEY_XF86RotationKB),
    ("XF86RotationLockToggle", KEY_XF86RotationLockToggle),
    ("XF86RotationPB", KEY_XF86RotationPB),
    ("XF86Save", KEY_XF86Save),
    ("XF86ScreenSaver", KEY_XF86ScreenSaver),
    ("XF86Screensaver", KEY_XF86Screensaver),
    ("XF86ScrollClick", KEY_XF86ScrollClick),
    ("XF86ScrollDown", KEY_XF86ScrollDown),
    ("XF86ScrollUp", KEY_XF86ScrollUp),
    ("XF86Search", KEY_XF86Search),
    ("XF86Select", KEY_XF86Select),
    ("XF86SelectiveScreenshot", KEY_XF86SelectiveScreenshot),
    ("XF86Send", KEY_XF86Send),
    ("XF86Shop", KEY_XF86Shop),
    ("XF86SidevuSonar", KEY_XF86SidevuSonar),
    ("XF86SingleRangeRadar", KEY_XF86SingleRangeRadar),
    ("XF86Sleep", KEY_XF86Sleep),
    ("XF86SlowReverse", KEY_XF86SlowReverse),
    ("XF86Sos", KEY_XF86Sos),
    ("XF86Spell", KEY_XF86Spell),
    ("XF86SpellCheck", KEY_XF86SpellCheck),
    ("XF86SplitScreen", KEY_XF86SplitScreen),
    ("XF86Standby", KEY_XF86Standby),
    ("XF86Start", KEY_XF86Start),
    ("XF86Stop", KEY_XF86Stop),
    ("XF86StopRecord", KEY_XF86StopRecord),
    ("XF86Subtitle", KEY_XF86Subtitle),
    ("XF86Support", KEY_XF86Support),
    ("XF86Suspend", KEY_XF86Suspend),
    ("XF86Switch_VT_1", KEY_XF86Switch_VT_1),
    ("XF86Switch_VT_10", KEY_XF86Switch_VT_10),
    ("XF86Switch_VT_11", KEY_XF86Switch_VT_11),
    ("XF86Switch_VT_12", KEY_XF86Switch_VT_12),
    ("XF86Switch_VT_2", KEY_XF86Switch_VT_2),
    ("XF86Switch_VT_3", KEY_XF86Switch_VT_3),
    ("XF86Switch_VT_4", KEY_XF86Switch_VT_4),
    ("XF86Switch_VT_5", KEY_XF86Switch_VT_5),
    ("XF86Switch_VT_6", KEY_XF86Switch_VT_6),
    ("XF86Switch_VT_7", KEY_XF86Switch_VT_7),
    ("XF86Switch_VT_8", KEY_XF86Switch_VT_8),
    ("XF86Switch_VT_9", KEY_XF86Switch_VT_9),
    ("XF86Taskmanager", KEY_XF86Taskmanager),
    ("XF86TaskPane", KEY_XF86TaskPane),
    ("XF86Terminal", KEY_XF86Terminal),
    ("XF86Time", KEY_XF86Time),
    ("XF86ToDoList", KEY_XF86ToDoList),
    ("XF86Tools", KEY_XF86Tools),
    ("XF86TopMenu", KEY_XF86TopMenu),
    ("XF86TouchpadOff", KEY_XF86TouchpadOff),
    ("XF86TouchpadOn", KEY_XF86TouchpadOn),
    ("XF86TouchpadToggle", KEY_XF86TouchpadToggle),
    ("XF86TraditionalSonar", KEY_XF86TraditionalSonar),
    ("XF86Travel", KEY_XF86Travel),
    ("XF86Ungrab", KEY_XF86Ungrab),
    ("XF86Unmute", KEY_XF86Unmute),
    ("XF86User1KB", KEY_XF86User1KB),
    ("XF86User2KB", KEY_XF86User2KB),
    ("XF86UserPB", KEY_XF86UserPB),
    ("XF86UWB", KEY_XF86UWB),
    ("XF86VendorHome", KEY_XF86VendorHome),
    ("XF86Video", KEY_XF86Video),
    ("XF86VideoPhone", KEY_XF86VideoPhone),
    ("XF86View", KEY_XF86View),
    ("XF86VOD", KEY_XF86VOD),
    ("XF86VoiceCommand", KEY_XF86VoiceCommand),
    ("XF86Voicemail", KEY_XF86Voicemail),
    ("XF86WakeUp", KEY_XF86WakeUp),
    ("XF86WebCam", KEY_XF86WebCam),
    ("XF86WheelButton", KEY_XF86WheelButton),
    ("XF86WLAN", KEY_XF86WLAN),
    ("XF86Word", KEY_XF86Word),
    ("XF86WPSButton", KEY_XF86WPSButton),
    ("XF86WWAN", KEY_XF86WWAN),
    ("XF86WWW", KEY_XF86WWW),
    ("XF86Xfer", KEY_XF86Xfer),
    ("XF86Yellow", KEY_XF86Yellow),
    ("XF86ZoomIn", KEY_XF86ZoomIn),
    ("XF86ZoomOut", KEY_XF86ZoomOut),
    ("XF86ZoomReset", KEY_XF86ZoomReset),
    ("Y", KEY_Y),
    ("y", KEY_y),
    ("Yacute", KEY_Yacute),
    ("yacute", KEY_yacute),
    ("Ybelowdot", KEY_Ybelowdot),
    ("ybelowdot", KEY_ybelowdot),
    ("Ycircumflex", KEY_Ycircumflex),
    ("ycircumflex", KEY_ycircumflex),
    ("Ydiaeresis", KEY_Ydiaeresis),
    ("ydiaeresis", KEY_ydiaeresis),
    ("yen", KEY_yen),
    ("Ygrave", KEY_Ygrave),
    ("ygrave", KEY_ygrave),
    ("Yhook", KEY_Yhook),
    ("yhook", KEY_yhook),
    ("Ytilde", KEY_Ytilde),
    ("ytilde", KEY_ytilde),
    ("Z", KEY_Z),
    ("z", KEY_z),
    ("Zabovedot", KEY_Zabovedot),
    ("zabovedot", KEY_zabovedot),
    ("Zacute", KEY_Zacute),
    ("zacute", KEY_zacute),
    ("Zcaron", KEY_Zcaron),
    ("zcaron", KEY_zcaron),
    ("Zen_Koho", KEY_Zen_Koho),
    ("Zenkaku", KEY_Zenkaku),
    ("Zenkaku_Hankaku", KEY_Zenkaku_Hankaku),
    ("zerosubscript", KEY_zerosubscript),
    ("zerosuperior", KEY_zerosuperior),
    ("Zstroke", KEY_Zstroke),
    ("zstroke", KEY_zstroke),
];
