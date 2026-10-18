||| The CSS Color Module Level 4 named colours as opaque packed `ARGB8`
||| values, plus `transparent`.
|||
||| Every opaque name carries its standard 24-bit sRGB value with alpha
||| `0xFF`; `transparent` is fully zero. The `*gray`/`*grey` spellings,
||| `aqua`/`cyan` and `fuchsia`/`magenta` are aliases carrying the same
||| value, as in CSS.
module Data.ColorCode.PredefinedARGB

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Data.ColorCode

-------------------------------------------------------------------------------
-- Red & Pink Colors
export red             : ARGB8; red             = MkARGB8 0xFFFF0000
export crimson         : ARGB8; crimson         = MkARGB8 0xFFDC143C
export firebrick       : ARGB8; firebrick       = MkARGB8 0xFFB22222
export darkred         : ARGB8; darkred         = MkARGB8 0xFF8B0000
export pink            : ARGB8; pink            = MkARGB8 0xFFFFC0CB
export lightpink       : ARGB8; lightpink       = MkARGB8 0xFFFFB6C1
export hotpink         : ARGB8; hotpink         = MkARGB8 0xFFFF69B4
export deeppink        : ARGB8; deeppink        = MkARGB8 0xFFFF1493
export mediumvioletred : ARGB8; mediumvioletred = MkARGB8 0xFFC71585
export palevioletred   : ARGB8; palevioletred   = MkARGB8 0xFFDB7093
export lightcoral      : ARGB8; lightcoral      = MkARGB8 0xFFF08080
export indianred       : ARGB8; indianred       = MkARGB8 0xFFCD5C5C

-------------------------------------------------------------------------------
-- Orange & Yellow Colors
export orange               : ARGB8; orange               = MkARGB8 0xFFFFA500
export darkorange           : ARGB8; darkorange           = MkARGB8 0xFFFF8C00
export coral                : ARGB8; coral                = MkARGB8 0xFFFF7F50
export tomato               : ARGB8; tomato               = MkARGB8 0xFFFF6347
export orangered            : ARGB8; orangered            = MkARGB8 0xFFFF4500
export salmon               : ARGB8; salmon               = MkARGB8 0xFFFA8072
export darksalmon           : ARGB8; darksalmon           = MkARGB8 0xFFE9967A
export lightsalmon          : ARGB8; lightsalmon          = MkARGB8 0xFFFFA07A
export yellow               : ARGB8; yellow               = MkARGB8 0xFFFFFF00
export gold                 : ARGB8; gold                 = MkARGB8 0xFFFFD700
export lightyellow          : ARGB8; lightyellow          = MkARGB8 0xFFFFFFE0
export lemonchiffon         : ARGB8; lemonchiffon         = MkARGB8 0xFFFFFACD
export lightgoldenrodyellow : ARGB8; lightgoldenrodyellow = MkARGB8 0xFFFAFAD2
export papayawhip           : ARGB8; papayawhip           = MkARGB8 0xFFFFEFD5
export moccasin             : ARGB8; moccasin             = MkARGB8 0xFFFFE4B5
export peachpuff            : ARGB8; peachpuff            = MkARGB8 0xFFFFDAB9
export palegoldenrod        : ARGB8; palegoldenrod        = MkARGB8 0xFFEEE8AA
export khaki                : ARGB8; khaki                = MkARGB8 0xFFF0E68C
export darkkhaki            : ARGB8; darkkhaki            = MkARGB8 0xFFBDB76B

-------------------------------------------------------------------------------
-- Green Colors
export green             : ARGB8; green             = MkARGB8 0xFF008000
export lime              : ARGB8; lime              = MkARGB8 0xFF00FF00
export darkgreen         : ARGB8; darkgreen         = MkARGB8 0xFF006400
export forestgreen       : ARGB8; forestgreen       = MkARGB8 0xFF228B22
export seagreen          : ARGB8; seagreen          = MkARGB8 0xFF2E8B57
export mediumseagreen    : ARGB8; mediumseagreen    = MkARGB8 0xFF3CB371
export darkseagreen      : ARGB8; darkseagreen      = MkARGB8 0xFF8FBC8F
export lightgreen        : ARGB8; lightgreen        = MkARGB8 0xFF90EE90
export palegreen         : ARGB8; palegreen         = MkARGB8 0xFF98FB98
export springgreen       : ARGB8; springgreen       = MkARGB8 0xFF00FF7F
export mediumspringgreen : ARGB8; mediumspringgreen = MkARGB8 0xFF00FA9A
export lawngreen         : ARGB8; lawngreen         = MkARGB8 0xFF7CFC00
export chartreuse        : ARGB8; chartreuse        = MkARGB8 0xFF7FFF00
export greenyellow       : ARGB8; greenyellow       = MkARGB8 0xFFADFF2F
export yellowgreen       : ARGB8; yellowgreen       = MkARGB8 0xFF9ACD32
export olivedrab         : ARGB8; olivedrab         = MkARGB8 0xFF6B8E23
export olive             : ARGB8; olive             = MkARGB8 0xFF808000
export darkolivegreen    : ARGB8; darkolivegreen    = MkARGB8 0xFF556B2F

-------------------------------------------------------------------------------
-- Cyan & Blue Colors
export cyan            : ARGB8; cyan            = MkARGB8 0xFF00FFFF
export aqua            : ARGB8; aqua            = MkARGB8 0xFF00FFFF
export darkcyan        : ARGB8; darkcyan        = MkARGB8 0xFF008B8B
export teal            : ARGB8; teal            = MkARGB8 0xFF008080
export lightcyan       : ARGB8; lightcyan       = MkARGB8 0xFFE0FFFF
export paleturquoise   : ARGB8; paleturquoise   = MkARGB8 0xFFAFEEEE
export aquamarine      : ARGB8; aquamarine      = MkARGB8 0xFF7FFFD4
export turquoise       : ARGB8; turquoise       = MkARGB8 0xFF40E0D0
export mediumturquoise : ARGB8; mediumturquoise = MkARGB8 0xFF48D1CC
export darkturquoise   : ARGB8; darkturquoise   = MkARGB8 0xFF00CED1
export lightseagreen   : ARGB8; lightseagreen   = MkARGB8 0xFF20B2AA
export cadetblue       : ARGB8; cadetblue       = MkARGB8 0xFF5F9EA0
export blue            : ARGB8; blue            = MkARGB8 0xFF0000FF
export mediumblue      : ARGB8; mediumblue      = MkARGB8 0xFF0000CD
export darkblue        : ARGB8; darkblue        = MkARGB8 0xFF00008B
export navy            : ARGB8; navy            = MkARGB8 0xFF000080
export midnightblue    : ARGB8; midnightblue    = MkARGB8 0xFF191970
export royalblue       : ARGB8; royalblue       = MkARGB8 0xFF4169E1
export dodgerblue      : ARGB8; dodgerblue      = MkARGB8 0xFF1E90FF
export deepskyblue     : ARGB8; deepskyblue     = MkARGB8 0xFF00BFFF
export skyblue         : ARGB8; skyblue         = MkARGB8 0xFF87CEEB
export lightskyblue    : ARGB8; lightskyblue    = MkARGB8 0xFF87CEFA
export steelblue       : ARGB8; steelblue       = MkARGB8 0xFF4682B4
export lightsteelblue  : ARGB8; lightsteelblue  = MkARGB8 0xFFB0C4DE
export cornflowerblue  : ARGB8; cornflowerblue  = MkARGB8 0xFF6495ED
export aliceblue       : ARGB8; aliceblue       = MkARGB8 0xFFF0F8FF

-------------------------------------------------------------------------------
-- Purple Colors
export purple          : ARGB8; purple          = MkARGB8 0xFF800080
export fuchsia         : ARGB8; fuchsia         = MkARGB8 0xFFFF00FF
export magenta         : ARGB8; magenta         = MkARGB8 0xFFFF00FF
export darkmagenta     : ARGB8; darkmagenta     = MkARGB8 0xFF8B008B
export violet          : ARGB8; violet          = MkARGB8 0xFFEE82EE
export darkviolet      : ARGB8; darkviolet      = MkARGB8 0xFF9400D3
export indigo          : ARGB8; indigo          = MkARGB8 0xFF4B0082
export rebeccapurple   : ARGB8; rebeccapurple   = MkARGB8 0xFF663399
export orchid          : ARGB8; orchid          = MkARGB8 0xFFDA70D6
export darkorchid      : ARGB8; darkorchid      = MkARGB8 0xFF9932CC
export plum            : ARGB8; plum            = MkARGB8 0xFFDDA0DD
export thistle         : ARGB8; thistle         = MkARGB8 0xFFD8BFD8
export lavender        : ARGB8; lavender        = MkARGB8 0xFFE6E6FA
export mediumpurple    : ARGB8; mediumpurple    = MkARGB8 0xFF9370DB
export slateblue       : ARGB8; slateblue       = MkARGB8 0xFF6A5ACD
export mediumslateblue : ARGB8; mediumslateblue = MkARGB8 0xFF7B68EE
export darkslateblue   : ARGB8; darkslateblue   = MkARGB8 0xFF483D8B

-------------------------------------------------------------------------------
-- Brown Colors
export brown          : ARGB8; brown          = MkARGB8 0xFFA52A2A
export maroon         : ARGB8; maroon         = MkARGB8 0xFF800000
export saddlebrown    : ARGB8; saddlebrown    = MkARGB8 0xFF8B4513
export sienna         : ARGB8; sienna         = MkARGB8 0xFFA0522D
export chocolate      : ARGB8; chocolate      = MkARGB8 0xFFD2691E
export peru           : ARGB8; peru           = MkARGB8 0xFFCD853F
export darkgoldenrod  : ARGB8; darkgoldenrod  = MkARGB8 0xFFB8860B
export goldenrod      : ARGB8; goldenrod      = MkARGB8 0xFFDAA520
export rosybrown      : ARGB8; rosybrown      = MkARGB8 0xFFBC8F8F
export sandybrown     : ARGB8; sandybrown     = MkARGB8 0xFFF4A460
export tan            : ARGB8; tan            = MkARGB8 0xFFD2B48C
export burlywood      : ARGB8; burlywood      = MkARGB8 0xFFDEB887
export wheat          : ARGB8; wheat          = MkARGB8 0xFFF5DEB3
export navajowhite    : ARGB8; navajowhite    = MkARGB8 0xFFFFDEAD
export bisque         : ARGB8; bisque         = MkARGB8 0xFFFFE4C4
export blanchedalmond : ARGB8; blanchedalmond = MkARGB8 0xFFFFEBCD
export cornsilk       : ARGB8; cornsilk       = MkARGB8 0xFFFFF8DC

-------------------------------------------------------------------------------
-- White, Gray & Black Colors
export white          : ARGB8; white          = MkARGB8 0xFFFFFFFF
export snow           : ARGB8; snow           = MkARGB8 0xFFFFFAFA
export honeydew       : ARGB8; honeydew       = MkARGB8 0xFFF0FFF0
export mintcream      : ARGB8; mintcream      = MkARGB8 0xFFF5FFFA
export azure          : ARGB8; azure          = MkARGB8 0xFFF0FFFF
export ghostwhite     : ARGB8; ghostwhite     = MkARGB8 0xFFF8F8FF
export whitesmoke     : ARGB8; whitesmoke     = MkARGB8 0xFFF5F5F5
export seashell       : ARGB8; seashell       = MkARGB8 0xFFFFF5EE
export beige          : ARGB8; beige          = MkARGB8 0xFFF5F5DC
export oldlace        : ARGB8; oldlace        = MkARGB8 0xFFFDF5E6
export floralwhite    : ARGB8; floralwhite    = MkARGB8 0xFFFFFAF0
export ivory          : ARGB8; ivory          = MkARGB8 0xFFFFFFF0
export antiquewhite   : ARGB8; antiquewhite   = MkARGB8 0xFFFAEBD7
export linen          : ARGB8; linen          = MkARGB8 0xFFFAF0E6
export lavenderblush  : ARGB8; lavenderblush  = MkARGB8 0xFFFFF0F5
export mistyrose      : ARGB8; mistyrose      = MkARGB8 0xFFFFE4E1
export gainsboro      : ARGB8; gainsboro      = MkARGB8 0xFFDCDCDC
export lightgray      : ARGB8; lightgray      = MkARGB8 0xFFD3D3D3
export lightgrey      : ARGB8; lightgrey      = MkARGB8 0xFFD3D3D3
export silver         : ARGB8; silver         = MkARGB8 0xFFC0C0C0
export darkgray       : ARGB8; darkgray       = MkARGB8 0xFFA9A9A9
export darkgrey       : ARGB8; darkgrey       = MkARGB8 0xFFA9A9A9
export gray           : ARGB8; gray           = MkARGB8 0xFF808080
export grey           : ARGB8; grey           = MkARGB8 0xFF808080
export dimgray        : ARGB8; dimgray        = MkARGB8 0xFF696969
export dimgrey        : ARGB8; dimgrey        = MkARGB8 0xFF696969
export lightslategray : ARGB8; lightslategray = MkARGB8 0xFF778899
export lightslategrey : ARGB8; lightslategrey = MkARGB8 0xFF778899
export slategray      : ARGB8; slategray      = MkARGB8 0xFF708090
export slategrey      : ARGB8; slategrey      = MkARGB8 0xFF708090
export darkslategray  : ARGB8; darkslategray  = MkARGB8 0xFF2F4F4F
export darkslategrey  : ARGB8; darkslategrey  = MkARGB8 0xFF2F4F4F
export black          : ARGB8; black          = MkARGB8 0xFF000000

-------------------------------------------------------------------------------
-- Other Keywords
export transparent    : ARGB8; transparent    = MkARGB8 0x00000000


