// Parley Reader markdown: a port of Parley's MarkdownParser (Sources/Parley/Views/MarkdownView.swift)
// and of what Foundation's AttributedString(markdown:, .inlineOnlyPreservingWhitespace) makes of each
// block's text, plus Parley's link rules (Views/LinkConfirmation.swift, PendingLink).
//
// It produces plain data, never DOM or HTML: parse(text) gives blocks, inline(text) gives runs of
// {text, styles, link}. The page builds DOM nodes from them with textContent only. Runs in the page
// and, for tests, in Node (tools/test_reader_markdown.mjs). No regex lookbehind, so older Safari
// can load it.
const ParleyMarkdown = (() => {
  'use strict';

  // ---------------------------------------------------------------------------------------------
  // Blocks (MarkdownParser.parse)

  /**
   * Swift's trimmingCharacters(in: .whitespaces): TAB and Unicode Zs only (not CR, LF, BOM).
   * Two index loops, one UTF-16 unit at a time (every Zs character is in the BMP): a regex with a
   * `[…]+$` branch backtracks over long runs of spaces inside a line and turns quadratic.
   */
  const TRIM_UNIT_RE = /^[\t\p{Zs}]$/u;
  function trim(s) {
    let a = 0, b = s.length;
    while (a < b && TRIM_UNIT_RE.test(s[a])) a++;
    while (b > a && TRIM_UNIT_RE.test(s[b - 1])) b--;
    return a === 0 && b === s.length ? s : s.slice(a, b);
  }

  /** components(separatedBy: "\n") on Characters: a "\r\n" pair is one Character, never a split. */
  function splitLines(text) {
    const lines = [];
    let start = 0;
    for (let i = 0; i < text.length; i++) {
      if (text.charCodeAt(i) === 10 && !(i > 0 && text.charCodeAt(i - 1) === 13)) {
        lines.push(text.slice(start, i));
        start = i + 1;
      }
    }
    lines.push(text.slice(start));
    return lines;
  }

  const BULLETS = ['•', '◦', '▪'];
  const TASKS = [['- [ ] ', '☐'], ['- [x] ', '☑'], ['- [X] ', '☑'], ['* [ ] ', '☐'], ['* [x] ', '☑']];

  function listItem(line) {
    let lead = 0, width = 0;
    while (lead < line.length && (line[lead] === ' ' || line[lead] === '\t')) {
      width += line[lead] === '\t' ? 4 : 1;
      lead++;
    }
    const indent = Math.min(Math.floor(width / 2), 5);
    const rest = line.slice(lead);
    for (const [prefix, marker] of TASKS) {
      if (rest.startsWith(prefix)) return { indent, marker, text: rest.slice(prefix.length) };
    }
    if (rest.startsWith('- ') || rest.startsWith('* ') || rest.startsWith('+ ')) {
      return { indent, marker: BULLETS[Math.min(indent, 2)], text: rest.slice(2) };
    }
    let digits = 0;
    while (digits < rest.length && rest[digits] >= '0' && rest[digits] <= '9') digits++;
    if (digits >= 1 && digits <= 3 && (rest[digits] === '.' || rest[digits] === ')') && rest[digits + 1] === ' ') {
      return { indent, marker: rest.slice(0, digits + 1), text: rest.slice(digits + 2) };
    }
    return null;
  }

  function onlyChar(s, ch) {
    for (let i = 0; i < s.length; i++) if (s[i] !== ch) return false;
    return true;
  }

  function parse(text) {
    const blocks = [];
    let paragraph = [], quote = [], list = [];
    const flushParagraph = () => {
      if (paragraph.length) { blocks.push({ type: 'paragraph', text: paragraph.join('\n') }); paragraph = []; }
    };
    const flushQuote = () => {
      if (quote.length) { blocks.push({ type: 'quote', text: quote.join('\n') }); quote = []; }
    };
    const flushList = () => {
      if (list.length) { blocks.push({ type: 'list', items: list }); list = []; }
    };
    const flushAll = () => { flushParagraph(); flushQuote(); flushList(); };

    const lines = splitLines(String(text));
    let i = 0;
    while (i < lines.length) {
      const line = lines[i];
      const t = trim(line);

      // Fenced code. An unclosed fence runs to the end (an interrupted reply).
      const fence = t.startsWith('```') ? '`' : t.startsWith('~~~') ? '~' : null;
      if (fence) {
        flushAll();
        const language = trim(t.slice(3));
        const code = [];
        i++;
        while (i < lines.length) {
          const u = trim(lines[i]);
          if (u.length >= 3 && onlyChar(u, fence)) break;
          code.push(lines[i]);
          i++;
        }
        blocks.push({ type: 'code', language, code: code.join('\n') });
        i++;
        continue;
      }

      if (t === '') { flushAll(); i++; continue; }

      if (t[0] === '#') {
        let h = 0;
        while (h < t.length && t[h] === '#') h++;
        const rest = t.slice(h);
        if (h <= 6 && (rest === '' || rest[0] === ' ')) {
          let content = trim(rest);
          while (content.endsWith('#')) content = content.slice(0, -1);
          flushAll();
          blocks.push({ type: 'heading', level: h, text: trim(content) });
          i++;
          continue;
        }
      }

      const compact = t.split(' ').join('');
      if (compact.length >= 3 && '-*_'.includes(compact[0]) && onlyChar(compact, compact[0])) {
        flushAll();
        blocks.push({ type: 'rule' });
        i++;
        continue;
      }

      const item = listItem(line);
      if (item) { flushParagraph(); flushQuote(); list.push(item); i++; continue; }

      if (list.length && (line[0] === ' ' || line[0] === '\t')) {
        list[list.length - 1].text += ' ' + t;
        i++;
        continue;
      }

      if (t[0] === '>') {
        flushParagraph(); flushList();
        let q = t.slice(1);
        if (q[0] === ' ') q = q.slice(1);
        quote.push(q);
        i++;
        continue;
      }

      flushQuote(); flushList();
      paragraph.push(line);
      i++;
    }
    flushAll();
    return blocks;
  }

  // ---------------------------------------------------------------------------------------------
  // Inline: a port of cmark-gfm's inline parser as Foundation runs it, with the observed quirks:
  // whitespace and line breaks are kept, a link's label is flattened to plain text, an image shows
  // its alt text, `^[text](…)` (Apple's attribute syntax) shows just its text, and leaving a nested
  // emphasis of the same kind ends that style for the rest of the outer one.

  // Tree nodes, doubly linked like cmark's, so emphasis can wrap ranges of siblings.
  function mk(type, literal) {
    return { type, literal: literal || '', url: '', parent: null, prev: null, next: null, first: null, last: null };
  }
  function append(parent, child) {
    child.parent = parent; child.next = null; child.prev = parent.last;
    if (parent.last) parent.last.next = child; else parent.first = child;
    parent.last = child;
  }
  function unlink(n) {
    if (n.prev) n.prev.next = n.next; else if (n.parent) n.parent.first = n.next;
    if (n.next) n.next.prev = n.prev; else if (n.parent) n.parent.last = n.prev;
    n.parent = n.prev = n.next = null;
  }
  function insertAfter(ref, n) {
    n.parent = ref.parent; n.prev = ref; n.next = ref.next;
    if (ref.next) ref.next.prev = n; else if (ref.parent) ref.parent.last = n;
    ref.next = n;
  }

  const ASCII_PUNCT = '!"#$%&\'()*+,-./:;<=>?@[\\]^_`{|}~';
  const isAsciiPunct = c => c !== undefined && c.length === 1 && ASCII_PUNCT.includes(c);
  const isAsciiAlpha = c => c !== undefined && /^[A-Za-z]$/.test(c);
  const isAsciiAlnum = c => c !== undefined && /^[A-Za-z0-9]$/.test(c);
  /** cmark_isspace: ASCII whitespace only. */
  const isCSpace = c => c === ' ' || c === '\t' || c === '\n' || c === '\v' || c === '\f' || c === '\r';
  /** cmark_utf8proc_is_space, on a code point. */
  function isUSpace(cp) {
    return cp === 9 || cp === 10 || cp === 12 || cp === 13 || cp === 32 || cp === 160 || cp === 5760
      || (cp >= 8192 && cp <= 8202) || cp === 8239 || cp === 8287 || cp === 12288;
  }
  const P_RE = /\p{P}/u;
  /** cmark_utf8proc_is_punctuation: ASCII punctuation or a Unicode P* letter (not symbols). */
  function isUPunct(cp) {
    if (cp < 128) return ASCII_PUNCT.includes(String.fromCharCode(cp));
    return P_RE.test(String.fromCodePoint(cp));
  }
  function codePointBefore(s, i) {
    if (i <= 0) return 10;
    const lo = s.charCodeAt(i - 1);
    if (lo >= 0xDC00 && lo <= 0xDFFF && i >= 2) {
      const hi = s.charCodeAt(i - 2);
      if (hi >= 0xD800 && hi <= 0xDBFF) return (hi - 0xD800) * 0x400 + (lo - 0xDC00) + 0x10000;
    }
    return lo;
  }
  function codePointAtOr(s, i) {
    return i >= s.length ? 10 : s.codePointAt(i);
  }

  // Entities: cmark decodes HTML5 named entities (with ';') and numeric ones.
  // Generated by tools/reader-tests/gen_entities.py; do not edit by hand.
  // BEGIN ENTITIES
  const ENTITY_TABLE = 'AElig:c6;AMP:26;Aacute:c1;Abreve:102;Acirc:c2;Acy:410;Afr:1d504;Agrave:c0;Alpha:391;Amacr:100;And:2a53;Aogon:104;Aopf:1d538;ApplyFunction:2061;Aring:c5;Ascr:1d49c;Assign:2254;Atilde:c3;Auml:c4;Backslash:2216;Barv:2ae7;Barwed:2306;Bcy:411;Because:2235;Bernoullis:212c;Beta:392;Bfr:1d505;Bopf:1d539;Breve:2d8;Bscr:212c;Bumpeq:224e;CHcy:427;COPY:a9;Cacute:106;Cap:22d2;CapitalDifferentialD:2145;Cayleys:212d;Ccaron:10c;Ccedil:c7;Ccirc:108;Cconint:2230;Cdot:10a;Cedilla:b8;CenterDot:b7;Cfr:212d;Chi:3a7;CircleDot:2299;CircleMinus:2296;CirclePlus:2295;CircleTimes:2297;ClockwiseContourIntegral:2232;CloseCurlyDoubleQuote:201d;CloseCurlyQuote:2019;Colon:2237;Colone:2a74;Congruent:2261;Conint:222f;ContourIntegral:222e;Copf:2102;Coproduct:2210;CounterClockwiseContourIntegral:2233;Cross:2a2f;Cscr:1d49e;Cup:22d3;CupCap:224d;DD:2145;DDotrahd:2911;DJcy:402;DScy:405;DZcy:40f;Dagger:2021;Darr:21a1;Dashv:2ae4;Dcaron:10e;Dcy:414;Del:2207;Delta:394;Dfr:1d507;DiacriticalAcute:b4;DiacriticalDot:2d9;DiacriticalDoubleAcute:2dd;DiacriticalGrave:60;DiacriticalTilde:2dc;Diamond:22c4;DifferentialD:2146;Dopf:1d53b;Dot:a8;DotDot:20dc;DotEqual:2250;DoubleContourIntegral:222f;DoubleDot:a8;DoubleDownArrow:21d3;DoubleLeftArrow:21d0;DoubleLeftRightArrow:21d4;DoubleLeftTee:2ae4;DoubleLongLeftArrow:27f8;DoubleLongLeftRightArrow:27fa;DoubleLongRightArrow:27f9;DoubleRightArrow:21d2;DoubleRightTee:22a8;DoubleUpArrow:21d1;DoubleUpDownArrow:21d5;DoubleVerticalBar:2225;DownArrow:2193;DownArrowBar:2913;DownArrowUpArrow:21f5;DownBreve:311;DownLeftRightVector:2950;DownLeftTeeVector:295e;DownLeftVector:21bd;DownLeftVectorBar:2956;DownRightTeeVector:295f;DownRightVector:21c1;DownRightVectorBar:2957;DownTee:22a4;DownTeeArrow:21a7;Downarrow:21d3;Dscr:1d49f;Dstrok:110;ENG:14a;ETH:d0;Eacute:c9;Ecaron:11a;Ecirc:ca;Ecy:42d;Edot:116;Efr:1d508;Egrave:c8;Element:2208;Emacr:112;EmptySmallSquare:25fb;EmptyVerySmallSquare:25ab;Eogon:118;Eopf:1d53c;Epsilon:395;Equal:2a75;EqualTilde:2242;Equilibrium:21cc;Escr:2130;Esim:2a73;Eta:397;Euml:cb;Exists:2203;ExponentialE:2147;Fcy:424;Ffr:1d509;FilledSmallSquare:25fc;FilledVerySmallSquare:25aa;Fopf:1d53d;ForAll:2200;Fouriertrf:2131;Fscr:2131;GJcy:403;GT:3e;Gamma:393;Gammad:3dc;Gbreve:11e;Gcedil:122;Gcirc:11c;Gcy:413;Gdot:120;Gfr:1d50a;Gg:22d9;Gopf:1d53e;GreaterEqual:2265;GreaterEqualLess:22db;GreaterFullEqual:2267;GreaterGreater:2aa2;GreaterLess:2277;GreaterSlantEqual:2a7e;GreaterTilde:2273;Gscr:1d4a2;Gt:226b;HARDcy:42a;Hacek:2c7;Hat:5e;Hcirc:124;Hfr:210c;HilbertSpace:210b;Hopf:210d;HorizontalLine:2500;Hscr:210b;Hstrok:126;HumpDownHump:224e;HumpEqual:224f;IEcy:415;IJlig:132;IOcy:401;Iacute:cd;Icirc:ce;Icy:418;Idot:130;Ifr:2111;Igrave:cc;Im:2111;Imacr:12a;ImaginaryI:2148;Implies:21d2;Int:222c;Integral:222b;Intersection:22c2;InvisibleComma:2063;InvisibleTimes:2062;Iogon:12e;Iopf:1d540;Iota:399;Iscr:2110;Itilde:128;Iukcy:406;Iuml:cf;Jcirc:134;Jcy:419;Jfr:1d50d;Jopf:1d541;Jscr:1d4a5;Jsercy:408;Jukcy:404;KHcy:425;KJcy:40c;Kappa:39a;Kcedil:136;Kcy:41a;Kfr:1d50e;Kopf:1d542;Kscr:1d4a6;LJcy:409;LT:3c;Lacute:139;Lambda:39b;Lang:27ea;Laplacetrf:2112;Larr:219e;Lcaron:13d;Lcedil:13b;Lcy:41b;LeftAngleBracket:27e8;LeftArrow:2190;LeftArrowBar:21e4;LeftArrowRightArrow:21c6;LeftCeiling:2308;LeftDoubleBracket:27e6;LeftDownTeeVector:2961;LeftDownVector:21c3;LeftDownVectorBar:2959;LeftFloor:230a;LeftRightArrow:2194;LeftRightVector:294e;LeftTee:22a3;LeftTeeArrow:21a4;LeftTeeVector:295a;LeftTriangle:22b2;LeftTriangleBar:29cf;LeftTriangleEqual:22b4;LeftUpDownVector:2951;LeftUpTeeVector:2960;LeftUpVector:21bf;LeftUpVectorBar:2958;LeftVector:21bc;LeftVectorBar:2952;Leftarrow:21d0;Leftrightarrow:21d4;LessEqualGreater:22da;LessFullEqual:2266;LessGreater:2276;LessLess:2aa1;LessSlantEqual:2a7d;LessTilde:2272;Lfr:1d50f;Ll:22d8;Lleftarrow:21da;Lmidot:13f;LongLeftArrow:27f5;LongLeftRightArrow:27f7;LongRightArrow:27f6;Longleftarrow:27f8;Longleftrightarrow:27fa;Longrightarrow:27f9;Lopf:1d543;LowerLeftArrow:2199;LowerRightArrow:2198;Lscr:2112;Lsh:21b0;Lstrok:141;Lt:226a;Map:2905;Mcy:41c;MediumSpace:205f;Mellintrf:2133;Mfr:1d510;MinusPlus:2213;Mopf:1d544;Mscr:2133;Mu:39c;NJcy:40a;Nacute:143;Ncaron:147;Ncedil:145;Ncy:41d;NegativeMediumSpace:200b;NegativeThickSpace:200b;NegativeThinSpace:200b;NegativeVeryThinSpace:200b;NestedGreaterGreater:226b;NestedLessLess:226a;NewLine:a;Nfr:1d511;NoBreak:2060;NonBreakingSpace:a0;Nopf:2115;Not:2aec;NotCongruent:2262;NotCupCap:226d;NotDoubleVerticalBar:2226;NotElement:2209;NotEqual:2260;NotEqualTilde:2242,338;NotExists:2204;NotGreater:226f;NotGreaterEqual:2271;NotGreaterFullEqual:2267,338;NotGreaterGreater:226b,338;NotGreaterLess:2279;NotGreaterSlantEqual:2a7e,338;NotGreaterTilde:2275;NotHumpDownHump:224e,338;NotHumpEqual:224f,338;NotLeftTriangle:22ea;NotLeftTriangleBar:29cf,338;NotLeftTriangleEqual:22ec;NotLess:226e;NotLessEqual:2270;NotLessGreater:2278;NotLessLess:226a,338;NotLessSlantEqual:2a7d,338;NotLessTilde:2274;NotNestedGreaterGreater:2aa2,338;NotNestedLessLess:2aa1,338;NotPrecedes:2280;NotPrecedesEqual:2aaf,338;NotPrecedesSlantEqual:22e0;NotReverseElement:220c;NotRightTriangle:22eb;NotRightTriangleBar:29d0,338;NotRightTriangleEqual:22ed;NotSquareSubset:228f,338;NotSquareSubsetEqual:22e2;NotSquareSuperset:2290,338;NotSquareSupersetEqual:22e3;NotSubset:2282,20d2;NotSubsetEqual:2288;NotSucceeds:2281;NotSucceedsEqual:2ab0,338;NotSucceedsSlantEqual:22e1;NotSucceedsTilde:227f,338;NotSuperset:2283,20d2;NotSupersetEqual:2289;NotTilde:2241;NotTildeEqual:2244;NotTildeFullEqual:2247;NotTildeTilde:2249;NotVerticalBar:2224;Nscr:1d4a9;Ntilde:d1;Nu:39d;OElig:152;Oacute:d3;Ocirc:d4;Ocy:41e;Odblac:150;Ofr:1d512;Ograve:d2;Omacr:14c;Omega:3a9;Omicron:39f;Oopf:1d546;OpenCurlyDoubleQuote:201c;OpenCurlyQuote:2018;Or:2a54;Oscr:1d4aa;Oslash:d8;Otilde:d5;Otimes:2a37;Ouml:d6;OverBar:203e;OverBrace:23de;OverBracket:23b4;OverParenthesis:23dc;PartialD:2202;Pcy:41f;Pfr:1d513;Phi:3a6;Pi:3a0;PlusMinus:b1;Poincareplane:210c;Popf:2119;Pr:2abb;Precedes:227a;PrecedesEqual:2aaf;PrecedesSlantEqual:227c;PrecedesTilde:227e;Prime:2033;Product:220f;Proportion:2237;Proportional:221d;Pscr:1d4ab;Psi:3a8;QUOT:22;Qfr:1d514;Qopf:211a;Qscr:1d4ac;RBarr:2910;REG:ae;Racute:154;Rang:27eb;Rarr:21a0;Rarrtl:2916;Rcaron:158;Rcedil:156;Rcy:420;Re:211c;ReverseElement:220b;ReverseEquilibrium:21cb;ReverseUpEquilibrium:296f;Rfr:211c;Rho:3a1;RightAngleBracket:27e9;RightArrow:2192;RightArrowBar:21e5;RightArrowLeftArrow:21c4;RightCeiling:2309;RightDoubleBracket:27e7;RightDownTeeVector:295d;RightDownVector:21c2;RightDownVectorBar:2955;RightFloor:230b;RightTee:22a2;RightTeeArrow:21a6;RightTeeVector:295b;RightTriangle:22b3;RightTriangleBar:29d0;RightTriangleEqual:22b5;RightUpDownVector:294f;RightUpTeeVector:295c;RightUpVector:21be;RightUpVectorBar:2954;RightVector:21c0;RightVectorBar:2953;Rightarrow:21d2;Ropf:211d;RoundImplies:2970;Rrightarrow:21db;Rscr:211b;Rsh:21b1;RuleDelayed:29f4;SHCHcy:429;SHcy:428;SOFTcy:42c;Sacute:15a;Sc:2abc;Scaron:160;Scedil:15e;Scirc:15c;Scy:421;Sfr:1d516;ShortDownArrow:2193;ShortLeftArrow:2190;ShortRightArrow:2192;ShortUpArrow:2191;Sigma:3a3;SmallCircle:2218;Sopf:1d54a;Sqrt:221a;Square:25a1;SquareIntersection:2293;SquareSubset:228f;SquareSubsetEqual:2291;SquareSuperset:2290;SquareSupersetEqual:2292;SquareUnion:2294;Sscr:1d4ae;Star:22c6;Sub:22d0;Subset:22d0;SubsetEqual:2286;Succeeds:227b;SucceedsEqual:2ab0;SucceedsSlantEqual:227d;SucceedsTilde:227f;SuchThat:220b;Sum:2211;Sup:22d1;Superset:2283;SupersetEqual:2287;Supset:22d1;THORN:de;TRADE:2122;TSHcy:40b;TScy:426;Tab:9;Tau:3a4;Tcaron:164;Tcedil:162;Tcy:422;Tfr:1d517;Therefore:2234;Theta:398;ThickSpace:205f,200a;ThinSpace:2009;Tilde:223c;TildeEqual:2243;TildeFullEqual:2245;TildeTilde:2248;Topf:1d54b;TripleDot:20db;Tscr:1d4af;Tstrok:166;Uacute:da;Uarr:219f;Uarrocir:2949;Ubrcy:40e;Ubreve:16c;Ucirc:db;Ucy:423;Udblac:170;Ufr:1d518;Ugrave:d9;Umacr:16a;UnderBar:5f;UnderBrace:23df;UnderBracket:23b5;UnderParenthesis:23dd;Union:22c3;UnionPlus:228e;Uogon:172;Uopf:1d54c;UpArrow:2191;UpArrowBar:2912;UpArrowDownArrow:21c5;UpDownArrow:2195;UpEquilibrium:296e;UpTee:22a5;UpTeeArrow:21a5;Uparrow:21d1;Updownarrow:21d5;UpperLeftArrow:2196;UpperRightArrow:2197;Upsi:3d2;Upsilon:3a5;Uring:16e;Uscr:1d4b0;Utilde:168;Uuml:dc;VDash:22ab;Vbar:2aeb;Vcy:412;Vdash:22a9;Vdashl:2ae6;Vee:22c1;Verbar:2016;Vert:2016;VerticalBar:2223;VerticalLine:7c;VerticalSeparator:2758;VerticalTilde:2240;VeryThinSpace:200a;Vfr:1d519;Vopf:1d54d;Vscr:1d4b1;Vvdash:22aa;Wcirc:174;Wedge:22c0;Wfr:1d51a;Wopf:1d54e;Wscr:1d4b2;Xfr:1d51b;Xi:39e;Xopf:1d54f;Xscr:1d4b3;YAcy:42f;YIcy:407;YUcy:42e;Yacute:dd;Ycirc:176;Ycy:42b;Yfr:1d51c;Yopf:1d550;Yscr:1d4b4;Yuml:178;ZHcy:416;Zacute:179;Zcaron:17d;Zcy:417;Zdot:17b;ZeroWidthSpace:200b;Zeta:396;Zfr:2128;Zopf:2124;Zscr:1d4b5;aacute:e1;abreve:103;ac:223e;acE:223e,333;acd:223f;acirc:e2;acute:b4;acy:430;aelig:e6;af:2061;afr:1d51e;agrave:e0;alefsym:2135;aleph:2135;alpha:3b1;amacr:101;amalg:2a3f;amp:26;and:2227;andand:2a55;andd:2a5c;andslope:2a58;andv:2a5a;ang:2220;ange:29a4;angle:2220;angmsd:2221;angmsdaa:29a8;angmsdab:29a9;angmsdac:29aa;angmsdad:29ab;angmsdae:29ac;angmsdaf:29ad;angmsdag:29ae;angmsdah:29af;angrt:221f;angrtvb:22be;angrtvbd:299d;angsph:2222;angst:c5;angzarr:237c;aogon:105;aopf:1d552;ap:2248;apE:2a70;apacir:2a6f;ape:224a;apid:224b;apos:27;approx:2248;approxeq:224a;aring:e5;ascr:1d4b6;ast:2a;asymp:2248;asympeq:224d;atilde:e3;auml:e4;awconint:2233;awint:2a11;bNot:2aed;backcong:224c;backepsilon:3f6;backprime:2035;backsim:223d;backsimeq:22cd;barvee:22bd;barwed:2305;barwedge:2305;bbrk:23b5;bbrktbrk:23b6;bcong:224c;bcy:431;bdquo:201e;becaus:2235;because:2235;bemptyv:29b0;bepsi:3f6;bernou:212c;beta:3b2;beth:2136;between:226c;bfr:1d51f;bigcap:22c2;bigcirc:25ef;bigcup:22c3;bigodot:2a00;bigoplus:2a01;bigotimes:2a02;bigsqcup:2a06;bigstar:2605;bigtriangledown:25bd;bigtriangleup:25b3;biguplus:2a04;bigvee:22c1;bigwedge:22c0;bkarow:290d;blacklozenge:29eb;blacksquare:25aa;blacktriangle:25b4;blacktriangledown:25be;blacktriangleleft:25c2;blacktriangleright:25b8;blank:2423;blk12:2592;blk14:2591;blk34:2593;block:2588;bne:3d,20e5;bnequiv:2261,20e5;bnot:2310;bopf:1d553;bot:22a5;bottom:22a5;bowtie:22c8;boxDL:2557;boxDR:2554;boxDl:2556;boxDr:2553;boxH:2550;boxHD:2566;boxHU:2569;boxHd:2564;boxHu:2567;boxUL:255d;boxUR:255a;boxUl:255c;boxUr:2559;boxV:2551;boxVH:256c;boxVL:2563;boxVR:2560;boxVh:256b;boxVl:2562;boxVr:255f;boxbox:29c9;boxdL:2555;boxdR:2552;boxdl:2510;boxdr:250c;boxh:2500;boxhD:2565;boxhU:2568;boxhd:252c;boxhu:2534;boxminus:229f;boxplus:229e;boxtimes:22a0;boxuL:255b;boxuR:2558;boxul:2518;boxur:2514;boxv:2502;boxvH:256a;boxvL:2561;boxvR:255e;boxvh:253c;boxvl:2524;boxvr:251c;bprime:2035;breve:2d8;brvbar:a6;bscr:1d4b7;bsemi:204f;bsim:223d;bsime:22cd;bsol:5c;bsolb:29c5;bsolhsub:27c8;bull:2022;bullet:2022;bump:224e;bumpE:2aae;bumpe:224f;bumpeq:224f;cacute:107;cap:2229;capand:2a44;capbrcup:2a49;capcap:2a4b;capcup:2a47;capdot:2a40;caps:2229,fe00;caret:2041;caron:2c7;ccaps:2a4d;ccaron:10d;ccedil:e7;ccirc:109;ccups:2a4c;ccupssm:2a50;cdot:10b;cedil:b8;cemptyv:29b2;cent:a2;centerdot:b7;cfr:1d520;chcy:447;check:2713;checkmark:2713;chi:3c7;cir:25cb;cirE:29c3;circ:2c6;circeq:2257;circlearrowleft:21ba;circlearrowright:21bb;circledR:ae;circledS:24c8;circledast:229b;circledcirc:229a;circleddash:229d;cire:2257;cirfnint:2a10;cirmid:2aef;cirscir:29c2;clubs:2663;clubsuit:2663;colon:3a;colone:2254;coloneq:2254;comma:2c;commat:40;comp:2201;compfn:2218;complement:2201;complexes:2102;cong:2245;congdot:2a6d;conint:222e;copf:1d554;coprod:2210;copy:a9;copysr:2117;crarr:21b5;cross:2717;cscr:1d4b8;csub:2acf;csube:2ad1;csup:2ad0;csupe:2ad2;ctdot:22ef;cudarrl:2938;cudarrr:2935;cuepr:22de;cuesc:22df;cularr:21b6;cularrp:293d;cup:222a;cupbrcap:2a48;cupcap:2a46;cupcup:2a4a;cupdot:228d;cupor:2a45;cups:222a,fe00;curarr:21b7;curarrm:293c;curlyeqprec:22de;curlyeqsucc:22df;curlyvee:22ce;curlywedge:22cf;curren:a4;curvearrowleft:21b6;curvearrowright:21b7;cuvee:22ce;cuwed:22cf;cwconint:2232;cwint:2231;cylcty:232d;dArr:21d3;dHar:2965;dagger:2020;daleth:2138;darr:2193;dash:2010;dashv:22a3;dbkarow:290f;dblac:2dd;dcaron:10f;dcy:434;dd:2146;ddagger:2021;ddarr:21ca;ddotseq:2a77;deg:b0;delta:3b4;demptyv:29b1;dfisht:297f;dfr:1d521;dharl:21c3;dharr:21c2;diam:22c4;diamond:22c4;diamondsuit:2666;diams:2666;die:a8;digamma:3dd;disin:22f2;div:f7;divide:f7;divideontimes:22c7;divonx:22c7;djcy:452;dlcorn:231e;dlcrop:230d;dollar:24;dopf:1d555;dot:2d9;doteq:2250;doteqdot:2251;dotminus:2238;dotplus:2214;dotsquare:22a1;doublebarwedge:2306;downarrow:2193;downdownarrows:21ca;downharpoonleft:21c3;downharpoonright:21c2;drbkarow:2910;drcorn:231f;drcrop:230c;dscr:1d4b9;dscy:455;dsol:29f6;dstrok:111;dtdot:22f1;dtri:25bf;dtrif:25be;duarr:21f5;duhar:296f;dwangle:29a6;dzcy:45f;dzigrarr:27ff;eDDot:2a77;eDot:2251;eacute:e9;easter:2a6e;ecaron:11b;ecir:2256;ecirc:ea;ecolon:2255;ecy:44d;edot:117;ee:2147;efDot:2252;efr:1d522;eg:2a9a;egrave:e8;egs:2a96;egsdot:2a98;el:2a99;elinters:23e7;ell:2113;els:2a95;elsdot:2a97;emacr:113;empty:2205;emptyset:2205;emptyv:2205;emsp:2003;emsp13:2004;emsp14:2005;eng:14b;ensp:2002;eogon:119;eopf:1d556;epar:22d5;eparsl:29e3;eplus:2a71;epsi:3b5;epsilon:3b5;epsiv:3f5;eqcirc:2256;eqcolon:2255;eqsim:2242;eqslantgtr:2a96;eqslantless:2a95;equals:3d;equest:225f;equiv:2261;equivDD:2a78;eqvparsl:29e5;erDot:2253;erarr:2971;escr:212f;esdot:2250;esim:2242;eta:3b7;eth:f0;euml:eb;euro:20ac;excl:21;exist:2203;expectation:2130;exponentiale:2147;fallingdotseq:2252;fcy:444;female:2640;ffilig:fb03;fflig:fb00;ffllig:fb04;ffr:1d523;filig:fb01;fjlig:66,6a;flat:266d;fllig:fb02;fltns:25b1;fnof:192;fopf:1d557;forall:2200;fork:22d4;forkv:2ad9;fpartint:2a0d;frac12:bd;frac13:2153;frac14:bc;frac15:2155;frac16:2159;frac18:215b;frac23:2154;frac25:2156;frac34:be;frac35:2157;frac38:215c;frac45:2158;frac56:215a;frac58:215d;frac78:215e;frasl:2044;frown:2322;fscr:1d4bb;gE:2267;gEl:2a8c;gacute:1f5;gamma:3b3;gammad:3dd;gap:2a86;gbreve:11f;gcirc:11d;gcy:433;gdot:121;ge:2265;gel:22db;geq:2265;geqq:2267;geqslant:2a7e;ges:2a7e;gescc:2aa9;gesdot:2a80;gesdoto:2a82;gesdotol:2a84;gesl:22db,fe00;gesles:2a94;gfr:1d524;gg:226b;ggg:22d9;gimel:2137;gjcy:453;gl:2277;glE:2a92;gla:2aa5;glj:2aa4;gnE:2269;gnap:2a8a;gnapprox:2a8a;gne:2a88;gneq:2a88;gneqq:2269;gnsim:22e7;gopf:1d558;grave:60;gscr:210a;gsim:2273;gsime:2a8e;gsiml:2a90;gt:3e;gtcc:2aa7;gtcir:2a7a;gtdot:22d7;gtlPar:2995;gtquest:2a7c;gtrapprox:2a86;gtrarr:2978;gtrdot:22d7;gtreqless:22db;gtreqqless:2a8c;gtrless:2277;gtrsim:2273;gvertneqq:2269,fe00;gvnE:2269,fe00;hArr:21d4;hairsp:200a;half:bd;hamilt:210b;hardcy:44a;harr:2194;harrcir:2948;harrw:21ad;hbar:210f;hcirc:125;hearts:2665;heartsuit:2665;hellip:2026;hercon:22b9;hfr:1d525;hksearow:2925;hkswarow:2926;hoarr:21ff;homtht:223b;hookleftarrow:21a9;hookrightarrow:21aa;hopf:1d559;horbar:2015;hscr:1d4bd;hslash:210f;hstrok:127;hybull:2043;hyphen:2010;iacute:ed;ic:2063;icirc:ee;icy:438;iecy:435;iexcl:a1;iff:21d4;ifr:1d526;igrave:ec;ii:2148;iiiint:2a0c;iiint:222d;iinfin:29dc;iiota:2129;ijlig:133;imacr:12b;image:2111;imagline:2110;imagpart:2111;imath:131;imof:22b7;imped:1b5;in:2208;incare:2105;infin:221e;infintie:29dd;inodot:131;int:222b;intcal:22ba;integers:2124;intercal:22ba;intlarhk:2a17;intprod:2a3c;iocy:451;iogon:12f;iopf:1d55a;iota:3b9;iprod:2a3c;iquest:bf;iscr:1d4be;isin:2208;isinE:22f9;isindot:22f5;isins:22f4;isinsv:22f3;isinv:2208;it:2062;itilde:129;iukcy:456;iuml:ef;jcirc:135;jcy:439;jfr:1d527;jmath:237;jopf:1d55b;jscr:1d4bf;jsercy:458;jukcy:454;kappa:3ba;kappav:3f0;kcedil:137;kcy:43a;kfr:1d528;kgreen:138;khcy:445;kjcy:45c;kopf:1d55c;kscr:1d4c0;lAarr:21da;lArr:21d0;lAtail:291b;lBarr:290e;lE:2266;lEg:2a8b;lHar:2962;lacute:13a;laemptyv:29b4;lagran:2112;lambda:3bb;lang:27e8;langd:2991;langle:27e8;lap:2a85;laquo:ab;larr:2190;larrb:21e4;larrbfs:291f;larrfs:291d;larrhk:21a9;larrlp:21ab;larrpl:2939;larrsim:2973;larrtl:21a2;lat:2aab;latail:2919;late:2aad;lates:2aad,fe00;lbarr:290c;lbbrk:2772;lbrace:7b;lbrack:5b;lbrke:298b;lbrksld:298f;lbrkslu:298d;lcaron:13e;lcedil:13c;lceil:2308;lcub:7b;lcy:43b;ldca:2936;ldquo:201c;ldquor:201e;ldrdhar:2967;ldrushar:294b;ldsh:21b2;le:2264;leftarrow:2190;leftarrowtail:21a2;leftharpoondown:21bd;leftharpoonup:21bc;leftleftarrows:21c7;leftrightarrow:2194;leftrightarrows:21c6;leftrightharpoons:21cb;leftrightsquigarrow:21ad;leftthreetimes:22cb;leg:22da;leq:2264;leqq:2266;leqslant:2a7d;les:2a7d;lescc:2aa8;lesdot:2a7f;lesdoto:2a81;lesdotor:2a83;lesg:22da,fe00;lesges:2a93;lessapprox:2a85;lessdot:22d6;lesseqgtr:22da;lesseqqgtr:2a8b;lessgtr:2276;lesssim:2272;lfisht:297c;lfloor:230a;lfr:1d529;lg:2276;lgE:2a91;lhard:21bd;lharu:21bc;lharul:296a;lhblk:2584;ljcy:459;ll:226a;llarr:21c7;llcorner:231e;llhard:296b;lltri:25fa;lmidot:140;lmoust:23b0;lmoustache:23b0;lnE:2268;lnap:2a89;lnapprox:2a89;lne:2a87;lneq:2a87;lneqq:2268;lnsim:22e6;loang:27ec;loarr:21fd;lobrk:27e6;longleftarrow:27f5;longleftrightarrow:27f7;longmapsto:27fc;longrightarrow:27f6;looparrowleft:21ab;looparrowright:21ac;lopar:2985;lopf:1d55d;loplus:2a2d;lotimes:2a34;lowast:2217;lowbar:5f;loz:25ca;lozenge:25ca;lozf:29eb;lpar:28;lparlt:2993;lrarr:21c6;lrcorner:231f;lrhar:21cb;lrhard:296d;lrm:200e;lrtri:22bf;lsaquo:2039;lscr:1d4c1;lsh:21b0;lsim:2272;lsime:2a8d;lsimg:2a8f;lsqb:5b;lsquo:2018;lsquor:201a;lstrok:142;lt:3c;ltcc:2aa6;ltcir:2a79;ltdot:22d6;lthree:22cb;ltimes:22c9;ltlarr:2976;ltquest:2a7b;ltrPar:2996;ltri:25c3;ltrie:22b4;ltrif:25c2;lurdshar:294a;luruhar:2966;lvertneqq:2268,fe00;lvnE:2268,fe00;mDDot:223a;macr:af;male:2642;malt:2720;maltese:2720;map:21a6;mapsto:21a6;mapstodown:21a7;mapstoleft:21a4;mapstoup:21a5;marker:25ae;mcomma:2a29;mcy:43c;mdash:2014;measuredangle:2221;mfr:1d52a;mho:2127;micro:b5;mid:2223;midast:2a;midcir:2af0;middot:b7;minus:2212;minusb:229f;minusd:2238;minusdu:2a2a;mlcp:2adb;mldr:2026;mnplus:2213;models:22a7;mopf:1d55e;mp:2213;mscr:1d4c2;mstpos:223e;mu:3bc;multimap:22b8;mumap:22b8;nGg:22d9,338;nGt:226b,20d2;nGtv:226b,338;nLeftarrow:21cd;nLeftrightarrow:21ce;nLl:22d8,338;nLt:226a,20d2;nLtv:226a,338;nRightarrow:21cf;nVDash:22af;nVdash:22ae;nabla:2207;nacute:144;nang:2220,20d2;nap:2249;napE:2a70,338;napid:224b,338;napos:149;napprox:2249;natur:266e;natural:266e;naturals:2115;nbsp:a0;nbump:224e,338;nbumpe:224f,338;ncap:2a43;ncaron:148;ncedil:146;ncong:2247;ncongdot:2a6d,338;ncup:2a42;ncy:43d;ndash:2013;ne:2260;neArr:21d7;nearhk:2924;nearr:2197;nearrow:2197;nedot:2250,338;nequiv:2262;nesear:2928;nesim:2242,338;nexist:2204;nexists:2204;nfr:1d52b;ngE:2267,338;nge:2271;ngeq:2271;ngeqq:2267,338;ngeqslant:2a7e,338;nges:2a7e,338;ngsim:2275;ngt:226f;ngtr:226f;nhArr:21ce;nharr:21ae;nhpar:2af2;ni:220b;nis:22fc;nisd:22fa;niv:220b;njcy:45a;nlArr:21cd;nlE:2266,338;nlarr:219a;nldr:2025;nle:2270;nleftarrow:219a;nleftrightarrow:21ae;nleq:2270;nleqq:2266,338;nleqslant:2a7d,338;nles:2a7d,338;nless:226e;nlsim:2274;nlt:226e;nltri:22ea;nltrie:22ec;nmid:2224;nopf:1d55f;not:ac;notin:2209;notinE:22f9,338;notindot:22f5,338;notinva:2209;notinvb:22f7;notinvc:22f6;notni:220c;notniva:220c;notnivb:22fe;notnivc:22fd;npar:2226;nparallel:2226;nparsl:2afd,20e5;npart:2202,338;npolint:2a14;npr:2280;nprcue:22e0;npre:2aaf,338;nprec:2280;npreceq:2aaf,338;nrArr:21cf;nrarr:219b;nrarrc:2933,338;nrarrw:219d,338;nrightarrow:219b;nrtri:22eb;nrtrie:22ed;nsc:2281;nsccue:22e1;nsce:2ab0,338;nscr:1d4c3;nshortmid:2224;nshortparallel:2226;nsim:2241;nsime:2244;nsimeq:2244;nsmid:2224;nspar:2226;nsqsube:22e2;nsqsupe:22e3;nsub:2284;nsubE:2ac5,338;nsube:2288;nsubset:2282,20d2;nsubseteq:2288;nsubseteqq:2ac5,338;nsucc:2281;nsucceq:2ab0,338;nsup:2285;nsupE:2ac6,338;nsupe:2289;nsupset:2283,20d2;nsupseteq:2289;nsupseteqq:2ac6,338;ntgl:2279;ntilde:f1;ntlg:2278;ntriangleleft:22ea;ntrianglelefteq:22ec;ntriangleright:22eb;ntrianglerighteq:22ed;nu:3bd;num:23;numero:2116;numsp:2007;nvDash:22ad;nvHarr:2904;nvap:224d,20d2;nvdash:22ac;nvge:2265,20d2;nvgt:3e,20d2;nvinfin:29de;nvlArr:2902;nvle:2264,20d2;nvlt:3c,20d2;nvltrie:22b4,20d2;nvrArr:2903;nvrtrie:22b5,20d2;nvsim:223c,20d2;nwArr:21d6;nwarhk:2923;nwarr:2196;nwarrow:2196;nwnear:2927;oS:24c8;oacute:f3;oast:229b;ocir:229a;ocirc:f4;ocy:43e;odash:229d;odblac:151;odiv:2a38;odot:2299;odsold:29bc;oelig:153;ofcir:29bf;ofr:1d52c;ogon:2db;ograve:f2;ogt:29c1;ohbar:29b5;ohm:3a9;oint:222e;olarr:21ba;olcir:29be;olcross:29bb;oline:203e;olt:29c0;omacr:14d;omega:3c9;omicron:3bf;omid:29b6;ominus:2296;oopf:1d560;opar:29b7;operp:29b9;oplus:2295;or:2228;orarr:21bb;ord:2a5d;order:2134;orderof:2134;ordf:aa;ordm:ba;origof:22b6;oror:2a56;orslope:2a57;orv:2a5b;oscr:2134;oslash:f8;osol:2298;otilde:f5;otimes:2297;otimesas:2a36;ouml:f6;ovbar:233d;par:2225;para:b6;parallel:2225;parsim:2af3;parsl:2afd;part:2202;pcy:43f;percnt:25;period:2e;permil:2030;perp:22a5;pertenk:2031;pfr:1d52d;phi:3c6;phiv:3d5;phmmat:2133;phone:260e;pi:3c0;pitchfork:22d4;piv:3d6;planck:210f;planckh:210e;plankv:210f;plus:2b;plusacir:2a23;plusb:229e;pluscir:2a22;plusdo:2214;plusdu:2a25;pluse:2a72;plusmn:b1;plussim:2a26;plustwo:2a27;pm:b1;pointint:2a15;popf:1d561;pound:a3;pr:227a;prE:2ab3;prap:2ab7;prcue:227c;pre:2aaf;prec:227a;precapprox:2ab7;preccurlyeq:227c;preceq:2aaf;precnapprox:2ab9;precneqq:2ab5;precnsim:22e8;precsim:227e;prime:2032;primes:2119;prnE:2ab5;prnap:2ab9;prnsim:22e8;prod:220f;profalar:232e;profline:2312;profsurf:2313;prop:221d;propto:221d;prsim:227e;prurel:22b0;pscr:1d4c5;psi:3c8;puncsp:2008;qfr:1d52e;qint:2a0c;qopf:1d562;qprime:2057;qscr:1d4c6;quaternions:210d;quatint:2a16;quest:3f;questeq:225f;quot:22;rAarr:21db;rArr:21d2;rAtail:291c;rBarr:290f;rHar:2964;race:223d,331;racute:155;radic:221a;raemptyv:29b3;rang:27e9;rangd:2992;range:29a5;rangle:27e9;raquo:bb;rarr:2192;rarrap:2975;rarrb:21e5;rarrbfs:2920;rarrc:2933;rarrfs:291e;rarrhk:21aa;rarrlp:21ac;rarrpl:2945;rarrsim:2974;rarrtl:21a3;rarrw:219d;ratail:291a;ratio:2236;rationals:211a;rbarr:290d;rbbrk:2773;rbrace:7d;rbrack:5d;rbrke:298c;rbrksld:298e;rbrkslu:2990;rcaron:159;rcedil:157;rceil:2309;rcub:7d;rcy:440;rdca:2937;rdldhar:2969;rdquo:201d;rdquor:201d;rdsh:21b3;real:211c;realine:211b;realpart:211c;reals:211d;rect:25ad;reg:ae;rfisht:297d;rfloor:230b;rfr:1d52f;rhard:21c1;rharu:21c0;rharul:296c;rho:3c1;rhov:3f1;rightarrow:2192;rightarrowtail:21a3;rightharpoondown:21c1;rightharpoonup:21c0;rightleftarrows:21c4;rightleftharpoons:21cc;rightrightarrows:21c9;rightsquigarrow:219d;rightthreetimes:22cc;ring:2da;risingdotseq:2253;rlarr:21c4;rlhar:21cc;rlm:200f;rmoust:23b1;rmoustache:23b1;rnmid:2aee;roang:27ed;roarr:21fe;robrk:27e7;ropar:2986;ropf:1d563;roplus:2a2e;rotimes:2a35;rpar:29;rpargt:2994;rppolint:2a12;rrarr:21c9;rsaquo:203a;rscr:1d4c7;rsh:21b1;rsqb:5d;rsquo:2019;rsquor:2019;rthree:22cc;rtimes:22ca;rtri:25b9;rtrie:22b5;rtrif:25b8;rtriltri:29ce;ruluhar:2968;rx:211e;sacute:15b;sbquo:201a;sc:227b;scE:2ab4;scap:2ab8;scaron:161;sccue:227d;sce:2ab0;scedil:15f;scirc:15d;scnE:2ab6;scnap:2aba;scnsim:22e9;scpolint:2a13;scsim:227f;scy:441;sdot:22c5;sdotb:22a1;sdote:2a66;seArr:21d8;searhk:2925;searr:2198;searrow:2198;sect:a7;semi:3b;seswar:2929;setminus:2216;setmn:2216;sext:2736;sfr:1d530;sfrown:2322;sharp:266f;shchcy:449;shcy:448;shortmid:2223;shortparallel:2225;shy:ad;sigma:3c3;sigmaf:3c2;sigmav:3c2;sim:223c;simdot:2a6a;sime:2243;simeq:2243;simg:2a9e;simgE:2aa0;siml:2a9d;simlE:2a9f;simne:2246;simplus:2a24;simrarr:2972;slarr:2190;smallsetminus:2216;smashp:2a33;smeparsl:29e4;smid:2223;smile:2323;smt:2aaa;smte:2aac;smtes:2aac,fe00;softcy:44c;sol:2f;solb:29c4;solbar:233f;sopf:1d564;spades:2660;spadesuit:2660;spar:2225;sqcap:2293;sqcaps:2293,fe00;sqcup:2294;sqcups:2294,fe00;sqsub:228f;sqsube:2291;sqsubset:228f;sqsubseteq:2291;sqsup:2290;sqsupe:2292;sqsupset:2290;sqsupseteq:2292;squ:25a1;square:25a1;squarf:25aa;squf:25aa;srarr:2192;sscr:1d4c8;ssetmn:2216;ssmile:2323;sstarf:22c6;star:2606;starf:2605;straightepsilon:3f5;straightphi:3d5;strns:af;sub:2282;subE:2ac5;subdot:2abd;sube:2286;subedot:2ac3;submult:2ac1;subnE:2acb;subne:228a;subplus:2abf;subrarr:2979;subset:2282;subseteq:2286;subseteqq:2ac5;subsetneq:228a;subsetneqq:2acb;subsim:2ac7;subsub:2ad5;subsup:2ad3;succ:227b;succapprox:2ab8;succcurlyeq:227d;succeq:2ab0;succnapprox:2aba;succneqq:2ab6;succnsim:22e9;succsim:227f;sum:2211;sung:266a;sup:2283;sup1:b9;sup2:b2;sup3:b3;supE:2ac6;supdot:2abe;supdsub:2ad8;supe:2287;supedot:2ac4;suphsol:27c9;suphsub:2ad7;suplarr:297b;supmult:2ac2;supnE:2acc;supne:228b;supplus:2ac0;supset:2283;supseteq:2287;supseteqq:2ac6;supsetneq:228b;supsetneqq:2acc;supsim:2ac8;supsub:2ad4;supsup:2ad6;swArr:21d9;swarhk:2926;swarr:2199;swarrow:2199;swnwar:292a;szlig:df;target:2316;tau:3c4;tbrk:23b4;tcaron:165;tcedil:163;tcy:442;tdot:20db;telrec:2315;tfr:1d531;there4:2234;therefore:2234;theta:3b8;thetasym:3d1;thetav:3d1;thickapprox:2248;thicksim:223c;thinsp:2009;thkap:2248;thksim:223c;thorn:fe;tilde:2dc;times:d7;timesb:22a0;timesbar:2a31;timesd:2a30;tint:222d;toea:2928;top:22a4;topbot:2336;topcir:2af1;topf:1d565;topfork:2ada;tosa:2929;tprime:2034;trade:2122;triangle:25b5;triangledown:25bf;triangleleft:25c3;trianglelefteq:22b4;triangleq:225c;triangleright:25b9;trianglerighteq:22b5;tridot:25ec;trie:225c;triminus:2a3a;triplus:2a39;trisb:29cd;tritime:2a3b;trpezium:23e2;tscr:1d4c9;tscy:446;tshcy:45b;tstrok:167;twixt:226c;twoheadleftarrow:219e;twoheadrightarrow:21a0;uArr:21d1;uHar:2963;uacute:fa;uarr:2191;ubrcy:45e;ubreve:16d;ucirc:fb;ucy:443;udarr:21c5;udblac:171;udhar:296e;ufisht:297e;ufr:1d532;ugrave:f9;uharl:21bf;uharr:21be;uhblk:2580;ulcorn:231c;ulcorner:231c;ulcrop:230f;ultri:25f8;umacr:16b;uml:a8;uogon:173;uopf:1d566;uparrow:2191;updownarrow:2195;upharpoonleft:21bf;upharpoonright:21be;uplus:228e;upsi:3c5;upsih:3d2;upsilon:3c5;upuparrows:21c8;urcorn:231d;urcorner:231d;urcrop:230e;uring:16f;urtri:25f9;uscr:1d4ca;utdot:22f0;utilde:169;utri:25b5;utrif:25b4;uuarr:21c8;uuml:fc;uwangle:29a7;vArr:21d5;vBar:2ae8;vBarv:2ae9;vDash:22a8;vangrt:299c;varepsilon:3f5;varkappa:3f0;varnothing:2205;varphi:3d5;varpi:3d6;varpropto:221d;varr:2195;varrho:3f1;varsigma:3c2;varsubsetneq:228a,fe00;varsubsetneqq:2acb,fe00;varsupsetneq:228b,fe00;varsupsetneqq:2acc,fe00;vartheta:3d1;vartriangleleft:22b2;vartriangleright:22b3;vcy:432;vdash:22a2;vee:2228;veebar:22bb;veeeq:225a;vellip:22ee;verbar:7c;vert:7c;vfr:1d533;vltri:22b2;vnsub:2282,20d2;vnsup:2283,20d2;vopf:1d567;vprop:221d;vrtri:22b3;vscr:1d4cb;vsubnE:2acb,fe00;vsubne:228a,fe00;vsupnE:2acc,fe00;vsupne:228b,fe00;vzigzag:299a;wcirc:175;wedbar:2a5f;wedge:2227;wedgeq:2259;weierp:2118;wfr:1d534;wopf:1d568;wp:2118;wr:2240;wreath:2240;wscr:1d4cc;xcap:22c2;xcirc:25ef;xcup:22c3;xdtri:25bd;xfr:1d535;xhArr:27fa;xharr:27f7;xi:3be;xlArr:27f8;xlarr:27f5;xmap:27fc;xnis:22fb;xodot:2a00;xopf:1d569;xoplus:2a01;xotime:2a02;xrArr:27f9;xrarr:27f6;xscr:1d4cd;xsqcup:2a06;xuplus:2a04;xutri:25b3;xvee:22c1;xwedge:22c0;yacute:fd;yacy:44f;ycirc:177;ycy:44b;yen:a5;yfr:1d536;yicy:457;yopf:1d56a;yscr:1d4ce;yucy:44e;yuml:ff;zacute:17a;zcaron:17e;zcy:437;zdot:17c;zeetrf:2128;zeta:3b6;zfr:1d537;zhcy:436;zigrarr:21dd;zopf:1d56b;zscr:1d4cf;zwj:200d;zwnj:200c';
  // END ENTITIES
  let entityMap = null;
  function entity(name) {
    if (!entityMap) {
      entityMap = new Map();
      for (const pair of ENTITY_TABLE.split(';')) {
        const colon = pair.indexOf(':');
        entityMap.set(pair.slice(0, colon), String.fromCodePoint(...pair.slice(colon + 1).split(',').map(h => parseInt(h, 16))));
      }
    }
    return entityMap.get(name);
  }

  /** houdini_unescape_ent at s[i] (just after '&'). Returns [decoded, length] or null. */
  function scanEntity(s, i) {
    if (s[i] === '#') {
      let j, cp = 0, digits = 0;
      if (s[i + 1] >= '0' && s[i + 1] <= '9') {
        for (j = i + 1; j < s.length && s[j] >= '0' && s[j] <= '9'; j++) cp = Math.min(cp * 10 + (s.charCodeAt(j) - 48), 0x110000);
        digits = j - i - 1;
      } else if (s[i + 1] === 'x' || s[i + 1] === 'X') {
        for (j = i + 2; j < s.length && /[0-9A-Fa-f]/.test(s[j]); j++) cp = Math.min(cp * 16 + parseInt(s[j], 16), 0x110000);
        digits = j - i - 2;
      } else {
        return null;
      }
      if (digits < 1 || digits > 8 || s[j] !== ';') return null;
      if (cp === 0 || (cp >= 0xD800 && cp < 0xE000) || cp >= 0x110000) cp = 0xFFFD;
      // Foundation drops these two noncharacters (observed).
      const text = (cp === 0xFFFE || cp === 0xFFFF) ? '' : String.fromCodePoint(cp);
      return [text, j + 1 - i];
    }
    const max = Math.min(s.length, i + 32);
    for (let j = i + 2; j < max; j++) {
      if (s[j] === ' ') break;
      if (s[j] === ';') {
        const value = entity(s.slice(i, j));
        return value === undefined ? null : [value, j + 1 - i];
      }
    }
    return null;
  }
  /** Decodes every entity in a string (link destinations, autolink text). */
  function decodeEntities(s) {
    let out = '', i = 0;
    while (i < s.length) {
      const amp = s.indexOf('&', i);
      if (amp < 0) { out += s.slice(i); break; }
      out += s.slice(i, amp);
      const e = scanEntity(s, amp + 1);
      if (e) { out += e[0]; i = amp + 1 + e[1]; } else { out += '&'; i = amp + 1; }
    }
    return out;
  }
  /** cmark_strbuf_unescape: backslash before ASCII punctuation. */
  function unescapeBackslashes(s) {
    let out = '';
    for (let i = 0; i < s.length; i++) {
      if (s[i] === '\\' && isAsciiPunct(s[i + 1])) { out += s[i + 1]; i++; } else out += s[i];
    }
    return out;
  }
  function cleanURL(raw) {
    const t = raw.replace(/^[ \t\n\v\f\r]+|[ \t\n\v\f\r]+$/g, '');
    return t === '' ? '' : unescapeBackslashes(decodeEntities(t));
  }

  const isSpaceChar = c => c === ' ' || c === '\t' || c === '\n' || c === '\v' || c === '\f' || c === '\r';
  function scanSpaces(s, i) {
    let j = i;
    while (j < s.length && isSpaceChar(s[j])) j++;
    return j - i;
  }

  /** manual_scan_link_url: returns {len, raw} or null. */
  function scanLinkURL(s, i) {
    if (s[i] === '<') {
      let j = i + 1;
      while (j < s.length) {
        const c = s[j];
        if (c === '>') { j++; break; }
        if (c === '\\') j += 2;
        else if (c === '\n' || c === '<') return null;
        else j++;
      }
      if (j >= s.length) return null;
      return { len: j - i, raw: s.slice(i + 1, j - 1) };
    }
    let j = i, depth = 0;
    while (j < s.length) {
      const c = s[j];
      if (c === '\\' && j + 1 < s.length && isAsciiPunct(s[j + 1])) j += 2;
      else if (c === '(') { depth++; j++; if (depth > 32) return null; }
      else if (c === ')') { if (depth === 0) break; depth--; j++; }
      else if (isCSpace(c)) { if (j === i) return null; break; }
      else j++;
    }
    if (j >= s.length || depth !== 0) return null;
    return { len: j - i, raw: s.slice(i, j) };
  }

  /**
   * scan_link_title with re2c's longest-match semantics, without a backtracking regex: a closing
   * quote preceded by a backslash may be either escaped or the end, so the last such one before a
   * definite end wins.
   */
  function scanTitle(s, i) {
    const open = s[i];
    if (open !== '"' && open !== "'" && open !== '(') return 0;
    const close = open === '(' ? ')' : open;
    let best = -1;
    for (let j = i + 1; j < s.length; j++) {
      const c = s[j];
      if (c === '\0') break;
      const escaped = s[j - 1] === '\\' && j - 1 > i;
      if (c === close) {
        best = j;
        if (!escaped) break;
      } else if (open === '(' && c === '(' && !escaped) {
        break;
      }
    }
    return best < 0 ? 0 : best + 1 - i;
  }

  /** Apple's `^[text](attributes)`: the attributes are a balanced parenthesised run. */
  function scanAttributes(s, i) {
    if (s[i] !== '(') return -1;
    let depth = 0, quoted = false;
    for (let j = i; j < s.length; j++) {
      const c = s[j];
      if (quoted) {
        if (c === '\\') j++;
        else if (c === '"') quoted = false;
      } else if (c === '"') quoted = true;
      else if (c === '(') depth++;
      else if (c === ')') { depth--; if (depth === 0) return j + 1; }
    }
    return -1;
  }

  // Raw HTML is shown literally, but it must be recognised so that markup inside a tag is not parsed.
  function scanAttrValue(s, j) {
    const c = s[j];
    if (c === '"' || c === "'") {
      const end = s.indexOf(c, j + 1);
      if (end < 0) return 0;
      return s.slice(j + 1, end).includes('\0') ? 0 : end + 1;
    }
    let k = j;
    while (k < s.length && !/[ \t\r\n\v\f"'=<>`\0]/.test(s[k])) k++;
    return k > j ? k : 0;
  }
  function scanOpenTag(s, i) {
    let j = i + 1;
    if (!isAsciiAlpha(s[j])) return 0;
    while (j < s.length && /[A-Za-z0-9-]/.test(s[j])) j++;
    for (;;) {
      let k = j;
      while (isSpaceChar(s[k])) k++;
      if (k === j || !/[A-Za-z_:]/.test(s[k] || '')) break;
      k++;
      while (k < s.length && /[A-Za-z0-9_.:-]/.test(s[k])) k++;
      let m = k;
      while (isSpaceChar(s[m])) m++;
      if (s[m] === '=') {
        m++;
        while (isSpaceChar(s[m])) m++;
        const v = scanAttrValue(s, m);
        if (v) k = v;
      }
      j = k;
    }
    while (isSpaceChar(s[j])) j++;
    if (s[j] === '/') j++;
    return s[j] === '>' ? j + 1 : 0;
  }
  const CLOSE_TAG_RE = /<\/[A-Za-z][A-Za-z0-9-]*[ \t\n\v\f\r]*>/y;
  const AUTOLINK_RE = /<([A-Za-z][A-Za-z0-9.+-]{1,31}:[^\x00-\x20<>]*)>/y;
  const EMAIL_RE = /<([a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*)>/y;

  function sticky(re, s, i) {
    re.lastIndex = i;
    return re.exec(s);
  }

  /** indexOf with a memo of failed searches, so many unclosed HTML comments stay linear. */
  function findFrom(st, needle, from) {
    const memo = st.found[needle];
    if (memo && memo.from <= from && (memo.at === -1 || memo.at >= from)) return memo.at;
    const at = st.s.indexOf(needle, from);
    st.found[needle] = { from, at };
    return at;
  }

  const COMMENT_OPEN = '<!' + '-' + '-';
  function scanHTML(st, i) {
    const s = st.s;
    const c = s[i + 1];
    if (c === '/') { const m = sticky(CLOSE_TAG_RE, s, i); return m ? i + m[0].length : 0; }
    if (c === '?') { const e = findFrom(st, '?>', i + 2); return e < 0 ? 0 : e + 2; }
    if (c === '!') {
      // (Spelled out so that this file can sit inside an HTML script element.)
      if (s.startsWith(COMMENT_OPEN, i)) {
        if (s.startsWith(COMMENT_OPEN + '>', i)) return i + 5;
        if (s.startsWith(COMMENT_OPEN + '->', i)) return i + 6;
        const e = findFrom(st, '-->', i + 4);
        return e < 0 ? 0 : e + 3;
      }
      if (s.startsWith('<![CDATA[', i)) { const e = findFrom(st, ']]>', i + 9); return e < 0 ? 0 : e + 3; }
      if (isAsciiAlpha(s[i + 2])) { const e = findFrom(st, '>', i + 2); return e < 0 ? 0 : e + 1; }
      return 0;
    }
    return scanOpenTag(s, i);
  }

  // GFM autolink extension (cmark-gfm autolink.c): bare http(s)/ftp URLs and www. addresses.
  /**
   * check_domain, byte loop emulated per code point (a multi-byte letter ends the domain). Both
   * callers only ask whether it is 0: an underscore in the last two labels, or (www.) no dot.
   *
   * Linear over a whole text: where the scan stops does not depend on where it starts, and every
   * character before the stop is ASCII, so one scan serves every later start inside it. The last
   * two dots of that scan and a prefix count of underscores give the answer for any such start.
   */
  function checkDomain(st, at, allowShort) {
    const s = st.s, from = at + 1;
    let scan = st.domain;
    if (!scan || from < scan.from || from > scan.end) {
      let lastDot = -1, prevDot = -1, j = from;
      while (j < s.length) {
        const cp = s.codePointAt(j);
        if (j + (cp > 0xFFFF ? 2 : 1) >= s.length && cp < 128) break; // the last byte is never examined
        if (cp === 46) { prevDot = lastDot; lastDot = j; }
        else if (cp >= 128) break; // the next byte is a continuation byte: invalid, stop
        else if (cp !== 45 && cp !== 95 && (isUSpace(cp) || isUPunct(cp))) break;
        j++; // ASCII from here on: one unit
      }
      scan = st.domain = { from, end: j, lastDot, prevDot };
    }
    if (!st.underscores) {
      const counts = new Int32Array(s.length + 1);
      for (let i = 0; i < s.length; i++) counts[i + 1] = counts[i] + (s.charCodeAt(i) === 95 ? 1 : 0);
      st.underscores = counts;
    }
    const us = (a, b) => st.underscores[b] - st.underscores[a];
    const end = scan.end;
    let us1 = 0, us2, np = 0;
    if (scan.lastDot >= from) {
      np = 1;
      us2 = us(scan.lastDot + 1, end);
      us1 = us(scan.prevDot >= from ? scan.prevDot + 1 : from, scan.lastDot);
    } else {
      us2 = us(from, end);
    }
    if (us1 > 0 || us2 > 0) return 0;
    return allowShort || np ? 1 : 0;
  }
  function autolinkDelim(s, base, end) {
    for (let i = 0; i < end; i++) if (s[base + i] === '<') { end = i; break; }
    // Parentheses are counted once; trimming only ever removes a ')' from them.
    let open = 0, close = 0;
    for (let i = 0; i < end; i++) {
      if (s[base + i] === '(') open++; else if (s[base + i] === ')') close++;
    }
    while (end > 0) {
      const last = s[base + end - 1];
      if ('?!.,:*_~\'"'.includes(last)) {
        end--;
      } else if (last === ';') {
        let k = end - 2;
        while (k > 0 && isAsciiAlpha(s[base + k])) k--;
        if (k < end - 2 && s[base + k] === '&') end = k; else end--;
      } else if (last === ')') {
        if (close <= open) break;
        end--;
        close--;
      } else {
        break;
      }
    }
    return end;
  }
  function linkEndFrom(s, p) {
    let e = p;
    while (e < s.length && !isCSpace(s[e]) && s[e] !== '<') e++;
    return e;
  }
  function addAutolink(st, url, text) {
    const link = mk('link');
    link.url = url;
    append(link, mk('text', text));
    append(st.root, link);
  }
  /** cmark_node_unput: take n characters back off the trailing text nodes. */
  function unput(root, n) {
    for (let node = root.last; n > 0 && node && node.type === 'text'; node = node.prev) {
      const take = Math.min(n, node.literal.length);
      node.literal = node.literal.slice(0, node.literal.length - take);
      n -= take;
    }
  }
  function urlMatch(st) {
    const s = st.s, p = st.pos;
    if (st.brackets || s.length - p < 4 || s[p + 1] !== '/' || s[p + 2] !== '/') return false;
    let rewind = 0;
    while (rewind < p && isAsciiAlpha(s[p - rewind - 1])) rewind++;
    const start = p - rewind;
    const safe = ['http://', 'https://', 'ftp://'].some(prefix =>
      s.length - start > prefix.length && s.slice(start, start + prefix.length).toLowerCase() === prefix
      && (isAsciiAlnum(s[start + prefix.length]) || s.charCodeAt(start + prefix.length) >= 128));
    if (!safe || checkDomain(st, p + 3, true) === 0) return false;
    const end = autolinkDelim(s, p, linkEndFrom(s, p + 3) - p);
    if (end === 0) return false;
    unput(st.root, rewind);
    st.pos = p + end;
    const url = s.slice(start, p + end);
    addAutolink(st, url, url);
    return true;
  }
  function wwwMatch(st) {
    const s = st.s, p = st.pos;
    if (st.brackets) return false;
    if (p > 0 && !'*_~('.includes(s[p - 1]) && !isCSpace(s[p - 1])) return false;
    if (!s.startsWith('www.', p) || checkDomain(st, p, false) === 0) return false;
    const end = autolinkDelim(s, p, linkEndFrom(s, p) - p);
    if (end === 0) return false;
    st.pos = p + end;
    const text = s.slice(p, p + end);
    addAutolink(st, 'http://' + text, text);
    return true;
  }

  function addText(st, text) {
    const n = mk('text', text);
    append(st.root, n);
    return n;
  }

  function handleDelim(st, c) {
    const s = st.s;
    const before = codePointBefore(s, st.pos);
    let n = 0;
    while (s[st.pos] === c) { st.pos++; n++; }
    const after = codePointAtOr(s, st.pos);
    const left = !isUSpace(after) && (!isUPunct(after) || isUSpace(before) || isUPunct(before));
    const right = !isUSpace(before) && (!isUPunct(before) || isUSpace(after) || isUPunct(after));
    let canOpen = left, canClose = right;
    if (c === '_') {
      canOpen = left && (!right || isUPunct(before));
      canClose = right && (!left || isUPunct(after));
    }
    const node = addText(st, c.repeat(n));
    // Strikethrough: runs of one or two tildes only.
    const push = c === '~' ? (left || right) && n <= 2 : (canOpen || canClose);
    if (push) {
      const d = { cc: c, numdelims: n, origdelims: n, node, canOpen, canClose, previous: st.delims, next: null };
      if (st.delims) st.delims.next = d;
      st.delims = d;
    }
  }

  function removeDelimiter(st, d) {
    if (d.previous) d.previous.next = d.next;
    if (d.next) d.next.previous = d.previous; else st.delims = d.previous;
  }

  /** process_emphasis (cmark 0.30 opener-bottom bookkeeping), with '~' for strikethrough. */
  function processEmphasis(st, stackBottom) {
    const bottoms = {};
    const keyOf = d => d.cc + (d.canOpen ? 3 : 0) + (d.origdelims % 3);
    let closer = st.delims;
    while (closer && closer.previous !== stackBottom) closer = closer.previous;
    while (closer) {
      if (!closer.canClose) { closer = closer.next; continue; }
      const key = keyOf(closer);
      const bottom = key in bottoms ? bottoms[key] : stackBottom;
      let opener = closer.previous, found = false;
      while (opener && opener !== stackBottom && opener !== bottom) {
        const odd = (closer.canOpen || opener.canClose) && closer.origdelims % 3 !== 0
          && (opener.origdelims + closer.origdelims) % 3 === 0;
        if (opener.cc === closer.cc && opener.canOpen && !odd) { found = true; break; }
        opener = opener.previous;
      }
      const oldCloser = closer;
      if (!found) {
        closer = closer.next;
      } else if (closer.cc === '~') {
        const next = closer.next;
        if (opener.numdelims === closer.numdelims) {
          const strike = mk('strike');
          for (let t = opener.node.next; t && t !== closer.node;) { const nx = t.next; unlink(t); append(strike, t); t = nx; }
          insertAfter(opener.node, strike);
          unlink(opener.node);
          unlink(closer.node);
        }
        for (let d = closer; d && d !== opener;) { const p = d.previous; removeDelimiter(st, d); d = p; }
        removeDelimiter(st, opener);
        closer = next;
      } else {
        const use = closer.numdelims >= 2 && opener.numdelims >= 2 ? 2 : 1;
        const on = opener.node, cn = closer.node;
        opener.numdelims -= use; closer.numdelims -= use;
        on.literal = on.literal.slice(0, on.literal.length - use);
        cn.literal = cn.literal.slice(0, cn.literal.length - use);
        const emph = mk(use === 1 ? 'emph' : 'strong');
        for (let t = on.next; t && t !== cn;) { const nx = t.next; unlink(t); append(emph, t); t = nx; }
        insertAfter(on, emph);
        // remove the delimiters between opener and closer
        for (let d = closer.previous; d && d !== opener;) { const p = d.previous; removeDelimiter(st, d); d = p; }
        if (opener.numdelims === 0) { unlink(on); removeDelimiter(st, opener); }
        if (closer.numdelims === 0) { unlink(cn); const nx = closer.next; removeDelimiter(st, closer); closer = nx; }
      }
      if (!found) {
        bottoms[key] = oldCloser.previous;
        if (!oldCloser.canOpen) removeDelimiter(st, oldCloser);
      }
    }
    while (st.delims && st.delims !== stackBottom) removeDelimiter(st, st.delims);
  }

  /** The nearest 'link' bracket at or below b (the stack is only ever popped from the top). */
  const linkAtOrBelow = b => (b && b.kind !== 'link' ? b.prevLink : b);
  function pushBracket(st, kind, node) {
    st.brackets = { kind, node, previous: st.brackets, prevLink: linkAtOrBelow(st.brackets), previousDelimiter: st.delims, active: true };
  }

  function handleCloseBracket(st) {
    const s = st.s;
    st.pos++;
    const opener = st.brackets;
    if (!opener) { addText(st, ']'); return; }
    if (!opener.active) { st.brackets = opener.previous; addText(st, ']'); return; }
    const afterLabel = st.pos;
    let matched = false, url = '';
    if (opener.kind === 'attr') {
      const end = scanAttributes(s, st.pos);
      if (end >= 0) { st.pos = end; matched = true; }
    } else if (s[st.pos] === '(') {
      const sps = scanSpaces(s, st.pos + 1);
      const dest = scanLinkURL(s, st.pos + 1 + sps);
      if (dest) {
        const endURL = st.pos + 1 + sps + dest.len;
        const startTitle = endURL + scanSpaces(s, endURL);
        const endTitle = startTitle === endURL ? startTitle : startTitle + scanTitle(s, startTitle);
        const endAll = endTitle + scanSpaces(s, endTitle);
        if (s[endAll] === ')') { st.pos = endAll + 1; url = cleanURL(dest.raw); matched = true; }
      }
    }
    if (!matched) {
      st.brackets = opener.previous;
      st.pos = afterLabel;
      addText(st, ']');
      return;
    }
    const node = mk(opener.kind);
    node.url = url;
    for (let t = opener.node.next; t;) { const nx = t.next; unlink(t); append(node, t); t = nx; }
    insertAfter(opener.node, node);
    unlink(opener.node);
    processEmphasis(st, opener.previousDelimiter);
    st.brackets = opener.previous;
    if (opener.kind === 'link') {
      // Only link brackets are deactivated: walk their chain, not every image bracket between.
      for (let b = linkAtOrBelow(st.brackets); b; b = b.prevLink) {
        if (!b.active) break;
        b.active = false;
      }
    }
  }

  // The scanner's stop characters; everything else is plain text.
  const SPECIAL = new Set(['\n', '\r', '\\', '`', '&', '_', '*', '[', ']', '<', '!', '~', ':', 'w', '^']);

  function backtickRuns(st) {
    // Positions of every maximal backtick run, by length, so unmatched openers stay linear.
    if (!st.runs) {
      st.runs = new Map();
      const s = st.s;
      for (let i = 0; i < s.length;) {
        if (s[i] !== '`') { i++; continue; }
        let j = i;
        while (s[j] === '`') j++;
        const len = j - i;
        if (!st.runs.has(len)) st.runs.set(len, []);
        st.runs.get(len).push(i);
        i = j;
      }
    }
    return st.runs;
  }

  function handleBackticks(st) {
    const s = st.s;
    const start = st.pos;
    while (s[st.pos] === '`') st.pos++;
    const n = st.pos - start;
    const list = backtickRuns(st).get(n) || [];
    // st.pos never moves back, so each run length keeps a cursor that only moves forward.
    let k = st.runCursor.get(n) || 0;
    while (k < list.length && list[k] < st.pos) k++;
    st.runCursor.set(n, k);
    const close = k < list.length ? list[k] : -1;
    if (close < 0) { addText(st, '`'.repeat(n)); return; }
    const raw = s.slice(st.pos, close);
    st.pos = close + n;
    // S_normalize_code: line endings become spaces; one space comes off each end if both have one.
    let out = '', nonSpace = false;
    for (let i = 0; i < raw.length; i++) {
      const c = raw[i];
      if (c === '\r') { if (raw[i + 1] !== '\n') out += ' '; } else if (c === '\n') out += ' '; else out += c;
      if (c !== ' ') nonSpace = true;
    }
    if (nonSpace && out[0] === ' ' && out[out.length - 1] === ' ') out = out.slice(1, -1);
    append(st.root, mk('code', out));
  }

  function parseInline(st) {
    const s = st.s;
    const c = s[st.pos];
    switch (c) {
      case '\n': case '\r':
        st.pos += c === '\r' && s[st.pos + 1] === '\n' ? 2 : 1;
        append(st.root, mk('softbreak'));
        return;
      case '\\': {
        const n = s[st.pos + 1];
        if (isAsciiPunct(n)) { st.pos += 2; addText(st, n); return; }
        if (n === '\n' || n === '\r') {
          st.pos += n === '\r' && s[st.pos + 2] === '\n' ? 3 : 2;
          append(st.root, mk('linebreak'));
          return;
        }
        st.pos++;
        addText(st, '\\');
        return;
      }
      case '`': handleBackticks(st); return;
      case '&': {
        const e = scanEntity(s, st.pos + 1);
        if (e) { st.pos += 1 + e[1]; addText(st, e[0]); } else { st.pos++; addText(st, '&'); }
        return;
      }
      case '<': {
        let m = sticky(AUTOLINK_RE, s, st.pos);
        if (m) {
          st.pos += m[0].length;
          addAutolink(st, decodeEntities(m[1]), decodeEntities(m[1]));
          return;
        }
        m = sticky(EMAIL_RE, s, st.pos);
        if (m) {
          st.pos += m[0].length;
          addAutolink(st, 'mailto:' + m[1], m[1]);
          return;
        }
        const end = scanHTML(st, st.pos);
        if (end) { append(st.root, mk('html', s.slice(st.pos, end))); st.pos = end; return; }
        st.pos++;
        addText(st, '<');
        return;
      }
      case '*': case '_': case '~': handleDelim(st, c); return;
      case '[': st.pos++; pushBracket(st, 'link', addText(st, '[')); return;
      case '!':
        if (s[st.pos + 1] === '[') { st.pos += 2; pushBracket(st, 'image', addText(st, '![')); return; }
        break;
      case '^':
        if (s[st.pos + 1] === '[') { st.pos += 2; pushBracket(st, 'attr', addText(st, '^[')); return; }
        break;
      case ']': handleCloseBracket(st); return;
      case ':': if (urlMatch(st)) return; break;
      case 'w': if (wwwMatch(st)) return; break;
      default: break;
    }
    // Plain text up to the next special character.
    let end = st.pos + 1;
    while (end < s.length && !SPECIAL.has(s[end])) end++;
    addText(st, s.slice(st.pos, end));
    st.pos = end;
  }

  function parseTree(text) {
    const st = { s: String(text).replace(/\0/g, '�'), pos: 0, root: mk('root'), delims: null, brackets: null, found: {}, runs: null, runCursor: new Map(), domain: null, underscores: null };
    while (st.pos < st.s.length) parseInline(st);
    processEmphasis(st, null);
    return st.root;
  }

  /** A link's label and an image's alt text become plain text, as Foundation renders them. */
  function flatten(node) {
    let out = '';
    for (let c = node.first; c; c = c.next) {
      if (c.type === 'text' || c.type === 'code' || c.type === 'html') out += c.literal;
      else if (c.type === 'softbreak') out += '\n';
      else if (c.type !== 'linebreak') out += flatten(c);
    }
    return out;
  }

  const STYLE_ORDER = ['em', 'strong', 'code', 'strike', 'html'];
  const STYLE_OF = { emph: 'em', strong: 'strong', strike: 'strike' };

  /**
   * Inline markdown to runs: [{text, styles: [...], link: null | PendingLink}] plus
   * {placeholder: true} for an image without alt text (Foundation shows U+FFFC there). Adjacent
   * plain runs with the same styles are merged; links are never merged.
   */
  function inline(text) {
    const runs = [];
    try {
      const active = new Set();
      const push = (t, extra, link, placeholder) => {
        if (t === '') return;
        const styles = STYLE_ORDER.filter(k => active.has(k) || k === extra);
        const last = runs[runs.length - 1];
        if (!link && !placeholder && last && !last.link && !last.placeholder && last.styles.join() === styles.join()) {
          last.text += t;
          return;
        }
        const run = { text: t, styles, link: link || null };
        if (placeholder) run.placeholder = true;
        runs.push(run);
      };
      const walk = node => {
        for (let c = node.first; c; c = c.next) {
          switch (c.type) {
            case 'text': push(c.literal); break;
            case 'softbreak': case 'linebreak': push('\n'); break;
            case 'code': push(c.literal, 'code'); break;
            case 'html': push(c.literal, 'html'); break;
            case 'emph': case 'strong': case 'strike': {
              // Foundation clears the style on leaving the inner span, even inside an outer one.
              const k = STYLE_OF[c.type];
              active.add(k); walk(c); active.delete(k);
              break;
            }
            case 'attr': walk(c); break;
            case 'link': push(flatten(c), null, pendingLink(c.url)); break;
            case 'image': {
              const alt = flatten(c);
              if (alt) push(alt); else push('￼', null, null, true);
              break;
            }
            default: break;
          }
        }
      };
      walk(parseTree(text));
      return runs;
    } catch (_) {
      // Like Swift's fallback when parsing throws (here: pathological nesting): the text as is.
      return text === '' ? [] : [{ text: String(text), styles: [], link: null }];
    }
  }

  // ---------------------------------------------------------------------------------------------
  // Links: PendingLink. A destination is normalised the way Foundation's URL(string:) does (not
  // WHATWG's URL parser, which reads hosts differently), then only plain http(s) addresses whose
  // host reads as it resolves survive.

  /** ToolDisplay.address: every scalar outside U+0021–U+007E as \u{HEX}. */
  function escapeAddress(s) {
    let out = '';
    for (const ch of String(s)) {
      const cp = ch.codePointAt(0);
      out += cp >= 0x21 && cp <= 0x7E ? ch : '\\u{' + cp.toString(16).toUpperCase() + '}';
    }
    return out;
  }

  /** ToolDisplay.visible: Cc, Cf, Zl, Zp and default-ignorables (not \n, \t) as \u{HEX}. */
  const HIDDEN_RE = /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}\p{Default_Ignorable_Code_Point}]/gu;
  function visible(s) {
    return String(s).replace(HIDDEN_RE, c => (c === '\n' || c === '\t') ? c
      : '\\u{' + c.codePointAt(0).toString(16).toUpperCase() + '}');
  }
  /** ToolDisplay.line: visible, and line breaks and tabs as \n and \t (for names in titles). */
  function line(s) {
    return visible(s).replace(/\n/g, '\\n').replace(/\t/g, '\\t');
  }

  // Foundation drops bidi controls from an address (observed); everything else it percent-encodes.
  const BIDI_RE = /[؜‎‏‪-‮⁦-⁩]/g;
  const UNRESERVED_SUB = "A-Za-z0-9\\-._~!$&'()*+,;=";
  const PATH_OK = new RegExp('[' + UNRESERVED_SUB + ':@/]');
  const QUERY_OK = new RegExp('[' + UNRESERVED_SUB + ':@/?]');
  const USER_OK = new RegExp('[' + UNRESERVED_SUB + ']');
  const HOST_OK = /^[A-Za-z0-9\-._~!$&'()*+,;=]*$/;
  const IPLITERAL_OK = /^[A-Za-z0-9\-._~!$&'()*+,;=:]+$/;
  const HEX2 = /^[0-9A-Fa-f]{2}$/;

  function pctEncodeChar(ch) {
    let out = '';
    for (const b of new TextEncoder().encode(ch)) out += '%' + (b < 16 ? '0' : '') + b.toString(16).toUpperCase();
    return out;
  }
  /** Keeps allowed characters and valid %XX; encodes the rest (as UTF-8) and a stray %. */
  function encodeComponent(s, ok, extra) {
    let out = '';
    const chars = Array.from(s);
    for (let i = 0; i < chars.length; i++) {
      const ch = chars[i];
      if (ch === '%') out += HEX2.test((chars[i + 1] || '') + (chars[i + 2] || '')) ? '%' : '%25';
      else if (ch.length === 1 && (ok.test(ch) || (extra && extra(ch, i)))) out += ch;
      else out += pctEncodeChar(ch);
    }
    return out;
  }

  /** IDNA for non-ASCII host labels, through the browser's own UTS #46 (on a throwaway host). */
  function idnaLabel(label) {
    try {
      const host = new URL('http://' + label + '.invalid/').hostname;
      if (!host.endsWith('.invalid')) return null;
      const out = host.slice(0, -'.invalid'.length);
      return out === '' ? null : out;
    } catch (_) {
      return null;
    }
  }
  function normaliseHost(host) {
    if (host.includes('%')) return null;
    // eslint-disable-next-line no-control-regex
    if (/^[\x00-\x7F]*$/.test(host)) return HOST_OK.test(host) ? host : null;
    // Non-ASCII: IDNA over the whole host, which refuses empty labels (a trailing dot is fine).
    const labels = host.split(/[.。．｡]/);
    const out = [];
    for (let i = 0; i < labels.length; i++) {
      const label = labels[i];
      if (label === '') { if (i === labels.length - 1 && i > 0) { out.push(''); continue; } return null; }
      const ascii = /^[\x00-\x7F]*$/.test(label) ? label : idnaLabel(label);
      if (ascii === null || !HOST_OK.test(ascii)) return null;
      out.push(ascii);
    }
    return out.join('.');
  }

  /**
   * The URL Foundation makes, for hierarchical addresses: returns {url, scheme, host} (host without
   * IPv6 brackets) or null when there would be no URL or no host. A markdown destination loses bidi
   * controls and gets a punycode host (observed). Plain URL(string:), used on an unwrapped
   * parley-link:, keeps a non-ASCII host percent-encoded, which PendingLink then refuses.
   */
  function normaliseURL(raw, plain) {
    const s = plain ? String(raw) : String(raw).replace(BIDI_RE, '');
    const m = /^([A-Za-z][A-Za-z0-9+.-]*):\/\//.exec(s);
    if (!m) return null;
    const scheme = m[1];
    let rest = s.slice(m[0].length);
    let cut = rest.search(/[/?#]/);
    if (cut < 0) cut = rest.length;
    const authority = rest.slice(0, cut);
    rest = rest.slice(cut);

    const at = authority.lastIndexOf('@');
    let userinfo = null, hostport = authority;
    if (at >= 0) { userinfo = authority.slice(0, at); hostport = authority.slice(at + 1); }

    let host, port = null, hostText;
    if (hostport[0] === '[') {
      const close = hostport.indexOf(']');
      if (close < 0) return null;
      host = hostport.slice(1, close);
      if (!IPLITERAL_OK.test(host)) return null;
      const after = hostport.slice(close + 1);
      if (after !== '') { if (after[0] !== ':') return null; port = after.slice(1); }
      hostText = '[' + host + ']';
    } else {
      const colon = hostport.indexOf(':');
      const name = colon < 0 ? hostport : hostport.slice(0, colon);
      if (colon >= 0) port = hostport.slice(colon + 1);
      host = plain && /[^\x00-\x7F]/.test(name) ? null : normaliseHost(name);
      if (host === null) return null;
      hostText = host;
    }
    if (host === '') return null;
    if (port !== null && !/^[0-9]*$/.test(port)) return null;

    let user = '';
    if (userinfo !== null) {
      let colonSeen = false;
      user = encodeComponent(userinfo, USER_OK, ch => {
        if (ch !== ':' || colonSeen) return false;
        colonSeen = true;
        return true;
      }) + '@';
    }

    // path, then ?query, then #fragment; a second # inside the fragment is encoded.
    let path = rest, query = null, fragment = null;
    const hash = path.indexOf('#');
    if (hash >= 0) { fragment = path.slice(hash + 1); path = path.slice(0, hash); }
    const q = path.indexOf('?');
    if (q >= 0) { query = path.slice(q + 1); path = path.slice(0, q); }

    const url = scheme + '://' + user + hostText + (port !== null ? ':' + port : '')
      + encodeComponent(path, PATH_OK)
      + (query !== null ? '?' + encodeComponent(query, QUERY_OK) : '')
      + (fragment !== null ? '#' + encodeComponent(fragment, QUERY_OK) : '');
    return { url, scheme, host };
  }

  const B64_RE = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;
  const INERT_PREFIX = 'parley-link:';

  /** PendingLink.real: one parley-link: layer comes off; if anything fails the original stays. */
  function unwrapInert(s) {
    if (!s.startsWith(INERT_PREFIX)) return null;
    const payload = s.slice(INERT_PREFIX.length);
    if (!B64_RE.test(payload)) return null;
    try {
      const bin = atob(payload);
      const bytes = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
      return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
    } catch (_) {
      return null;
    }
  }

  /** A host a browser reads differently (percent-encoding, numeric IPv4 forms, none) is refused. */
  function readsAsItResolves(host) {
    if (host === '' || host.includes('%')) return false;
    if (host.includes(':')) return true;
    const labels = host.toLowerCase().split('.').filter(l => l !== '');
    if (!labels.length) return false;
    const last = labels[labels.length - 1];
    const endsInNumber = /^[0-9]+$/.test(last) || /^0x[0-9a-f]*$/.test(last);
    if (!endsInNumber) return true;
    return labels.length === 4 && labels.every(l => /^(0|[1-9][0-9]{0,2})$/.test(l) && Number(l) <= 255);
  }

  /**
   * PendingLink(destination): {url, host, address, hasHiddenCharacters} for an address Parley would
   * open after confirmation, or null (the link then shows as plain text).
   */
  function pendingLink(destination) {
    if (typeof destination !== 'string') return null;
    const s = destination.replace(BIDI_RE, '');
    const inner = unwrapInert(s);
    const parsed = inner !== null ? normaliseURL(inner, true) : normaliseURL(s, false);
    if (!parsed) return null;
    const scheme = parsed.scheme.toLowerCase();
    if (scheme !== 'http' && scheme !== 'https') return null;
    if (!readsAsItResolves(parsed.host)) return null;
    const address = escapeAddress(parsed.url);
    return { url: parsed.url, host: escapeAddress(parsed.host), address, hasHiddenCharacters: address !== parsed.url };
  }

  /**
   * The confirmation gate (AppState.requestOpen / confirmPendingLink): one pending link at a time;
   * a refused address never asks; confirming opens once; cancelling or locking clears it.
   */
  function createLinkGate(open, ask) {
    let pending = null;
    return {
      get pending() { return pending; },
      requestOpen(url) {
        const link = pendingLink(url);
        if (!link) return false;
        pending = link;
        if (ask) ask(link);
        return true;
      },
      confirm() {
        const link = pending;
        pending = null;
        if (link) open(link.url);
        return !!link;
      },
      cancel() { pending = null; },
    };
  }

  return { parse, inline, trim, pendingLink, escapeAddress, visible, line, createLinkGate };
})();
if (typeof globalThis !== 'undefined') globalThis.ParleyMarkdown = ParleyMarkdown;
