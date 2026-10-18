||| The CSS Color Module Level 4 named colours as opaque packed `RGBA8`
||| values, plus `transparent`.
|||
||| Every opaque name carries its standard 24-bit sRGB value with alpha
||| `0xFF`; `transparent` is fully zero. The `*gray`/`*grey` spellings,
||| `aqua`/`cyan` and `fuchsia`/`magenta` are aliases carrying the same
||| value, as in CSS.
module Data.ColorCode.PredefinedRGBA

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Data.ColorCode

-------------------------------------------------------------------------------
-- Red & Pink Colors
export red             : RGBA8; red             = MkRGBA8 0xFF0000FF
export crimson         : RGBA8; crimson         = MkRGBA8 0xDC143CFF
export firebrick       : RGBA8; firebrick       = MkRGBA8 0xB22222FF
export darkred         : RGBA8; darkred         = MkRGBA8 0x8B0000FF
export pink            : RGBA8; pink            = MkRGBA8 0xFFC0CBFF
export lightpink       : RGBA8; lightpink       = MkRGBA8 0xFFB6C1FF
export hotpink         : RGBA8; hotpink         = MkRGBA8 0xFF69B4FF
export deeppink        : RGBA8; deeppink        = MkRGBA8 0xFF1493FF
export mediumvioletred : RGBA8; mediumvioletred = MkRGBA8 0xC71585FF
export palevioletred   : RGBA8; palevioletred   = MkRGBA8 0xDB7093FF
export lightcoral      : RGBA8; lightcoral      = MkRGBA8 0xF08080FF
export indianred       : RGBA8; indianred       = MkRGBA8 0xCD5C5CFF

-------------------------------------------------------------------------------
-- Orange & Yellow Colors
export orange               : RGBA8; orange               = MkRGBA8 0xFFA500FF
export darkorange           : RGBA8; darkorange           = MkRGBA8 0xFF8C00FF
export coral                : RGBA8; coral                = MkRGBA8 0xFF7F50FF
export tomato               : RGBA8; tomato               = MkRGBA8 0xFF6347FF
export orangered            : RGBA8; orangered            = MkRGBA8 0xFF4500FF
export salmon               : RGBA8; salmon               = MkRGBA8 0xFA8072FF
export darksalmon           : RGBA8; darksalmon           = MkRGBA8 0xE9967AFF
export lightsalmon          : RGBA8; lightsalmon          = MkRGBA8 0xFFA07AFF
export yellow               : RGBA8; yellow               = MkRGBA8 0xFFFF00FF
export gold                 : RGBA8; gold                 = MkRGBA8 0xFFD700FF
export lightyellow          : RGBA8; lightyellow          = MkRGBA8 0xFFFFE0FF
export lemonchiffon         : RGBA8; lemonchiffon         = MkRGBA8 0xFFFACDFF
export lightgoldenrodyellow : RGBA8; lightgoldenrodyellow = MkRGBA8 0xFAFAD2FF
export papayawhip           : RGBA8; papayawhip           = MkRGBA8 0xFFEFD5FF
export moccasin             : RGBA8; moccasin             = MkRGBA8 0xFFE4B5FF
export peachpuff            : RGBA8; peachpuff            = MkRGBA8 0xFFDAB9FF
export palegoldenrod        : RGBA8; palegoldenrod        = MkRGBA8 0xEEE8AAFF
export khaki                : RGBA8; khaki                = MkRGBA8 0xF0E68CFF
export darkkhaki            : RGBA8; darkkhaki            = MkRGBA8 0xBDB76BFF

-------------------------------------------------------------------------------
-- Green Colors
export green             : RGBA8; green             = MkRGBA8 0x008000FF
export lime              : RGBA8; lime              = MkRGBA8 0x00FF00FF
export darkgreen         : RGBA8; darkgreen         = MkRGBA8 0x006400FF
export forestgreen       : RGBA8; forestgreen       = MkRGBA8 0x228B22FF
export seagreen          : RGBA8; seagreen          = MkRGBA8 0x2E8B57FF
export mediumseagreen    : RGBA8; mediumseagreen    = MkRGBA8 0x3CB371FF
export darkseagreen      : RGBA8; darkseagreen      = MkRGBA8 0x8FBC8FFF
export lightgreen        : RGBA8; lightgreen        = MkRGBA8 0x90EE90FF
export palegreen         : RGBA8; palegreen         = MkRGBA8 0x98FB98FF
export springgreen       : RGBA8; springgreen       = MkRGBA8 0x00FF7FFF
export mediumspringgreen : RGBA8; mediumspringgreen = MkRGBA8 0x00FA9AFF
export lawngreen         : RGBA8; lawngreen         = MkRGBA8 0x7CFC00FF
export chartreuse        : RGBA8; chartreuse        = MkRGBA8 0x7FFF00FF
export greenyellow       : RGBA8; greenyellow       = MkRGBA8 0xADFF2FFF
export yellowgreen       : RGBA8; yellowgreen       = MkRGBA8 0x9ACD32FF
export olivedrab         : RGBA8; olivedrab         = MkRGBA8 0x6B8E23FF
export olive             : RGBA8; olive             = MkRGBA8 0x808000FF
export darkolivegreen    : RGBA8; darkolivegreen    = MkRGBA8 0x556B2FFF

-------------------------------------------------------------------------------
-- Cyan & Blue Colors
export cyan            : RGBA8; cyan            = MkRGBA8 0x00FFFFFF
export aqua            : RGBA8; aqua            = MkRGBA8 0x00FFFFFF
export darkcyan        : RGBA8; darkcyan        = MkRGBA8 0x008B8BFF
export teal            : RGBA8; teal            = MkRGBA8 0x008080FF
export lightcyan       : RGBA8; lightcyan       = MkRGBA8 0xE0FFFFFF
export paleturquoise   : RGBA8; paleturquoise   = MkRGBA8 0xAFEEEEFF
export aquamarine      : RGBA8; aquamarine      = MkRGBA8 0x7FFFD4FF
export turquoise       : RGBA8; turquoise       = MkRGBA8 0x40E0D0FF
export mediumturquoise : RGBA8; mediumturquoise = MkRGBA8 0x48D1CCFF
export darkturquoise   : RGBA8; darkturquoise   = MkRGBA8 0x00CED1FF
export lightseagreen   : RGBA8; lightseagreen   = MkRGBA8 0x20B2AAFF
export cadetblue       : RGBA8; cadetblue       = MkRGBA8 0x5F9EA0FF
export blue            : RGBA8; blue            = MkRGBA8 0x0000FFFF
export mediumblue      : RGBA8; mediumblue      = MkRGBA8 0x0000CDFF
export darkblue        : RGBA8; darkblue        = MkRGBA8 0x00008BFF
export navy            : RGBA8; navy            = MkRGBA8 0x000080FF
export midnightblue    : RGBA8; midnightblue    = MkRGBA8 0x191970FF
export royalblue       : RGBA8; royalblue       = MkRGBA8 0x4169E1FF
export dodgerblue      : RGBA8; dodgerblue      = MkRGBA8 0x1E90FFFF
export deepskyblue     : RGBA8; deepskyblue     = MkRGBA8 0x00BFFFFF
export skyblue         : RGBA8; skyblue         = MkRGBA8 0x87CEEBFF
export lightskyblue    : RGBA8; lightskyblue    = MkRGBA8 0x87CEFAFF
export steelblue       : RGBA8; steelblue       = MkRGBA8 0x4682B4FF
export lightsteelblue  : RGBA8; lightsteelblue  = MkRGBA8 0xB0C4DEFF
export cornflowerblue  : RGBA8; cornflowerblue  = MkRGBA8 0x6495EDFF
export aliceblue       : RGBA8; aliceblue       = MkRGBA8 0xF0F8FFFF

-------------------------------------------------------------------------------
-- Purple Colors
export purple          : RGBA8; purple          = MkRGBA8 0x800080FF
export fuchsia         : RGBA8; fuchsia         = MkRGBA8 0xFF00FFFF
export magenta         : RGBA8; magenta         = MkRGBA8 0xFF00FFFF
export darkmagenta     : RGBA8; darkmagenta     = MkRGBA8 0x8B008BFF
export violet          : RGBA8; violet          = MkRGBA8 0xEE82EEFF
export darkviolet      : RGBA8; darkviolet      = MkRGBA8 0x9400D3FF
export indigo          : RGBA8; indigo          = MkRGBA8 0x4B0082FF
export rebeccapurple   : RGBA8; rebeccapurple   = MkRGBA8 0x663399FF
export orchid          : RGBA8; orchid          = MkRGBA8 0xDA70D6FF
export darkorchid      : RGBA8; darkorchid      = MkRGBA8 0x9932CCFF
export plum            : RGBA8; plum            = MkRGBA8 0xDDA0DDFF
export thistle         : RGBA8; thistle         = MkRGBA8 0xD8BFD8FF
export lavender        : RGBA8; lavender        = MkRGBA8 0xE6E6FAFF
export mediumpurple    : RGBA8; mediumpurple    = MkRGBA8 0x9370DBFF
export slateblue       : RGBA8; slateblue       = MkRGBA8 0x6A5ACDFF
export mediumslateblue : RGBA8; mediumslateblue = MkRGBA8 0x7B68EEFF
export darkslateblue   : RGBA8; darkslateblue   = MkRGBA8 0x483D8BFF

-------------------------------------------------------------------------------
-- Brown Colors
export brown          : RGBA8; brown          = MkRGBA8 0xA52A2AFF
export maroon         : RGBA8; maroon         = MkRGBA8 0x800000FF
export saddlebrown    : RGBA8; saddlebrown    = MkRGBA8 0x8B4513FF
export sienna         : RGBA8; sienna         = MkRGBA8 0xA0522DFF
export chocolate      : RGBA8; chocolate      = MkRGBA8 0xD2691EFF
export peru           : RGBA8; peru           = MkRGBA8 0xCD853FFF
export darkgoldenrod  : RGBA8; darkgoldenrod  = MkRGBA8 0xB8860BFF
export goldenrod      : RGBA8; goldenrod      = MkRGBA8 0xDAA520FF
export rosybrown      : RGBA8; rosybrown      = MkRGBA8 0xBC8F8FFF
export sandybrown     : RGBA8; sandybrown     = MkRGBA8 0xF4A460FF
export tan            : RGBA8; tan            = MkRGBA8 0xD2B48CFF
export burlywood      : RGBA8; burlywood      = MkRGBA8 0xDEB887FF
export wheat          : RGBA8; wheat          = MkRGBA8 0xF5DEB3FF
export navajowhite    : RGBA8; navajowhite    = MkRGBA8 0xFFDEADFF
export bisque         : RGBA8; bisque         = MkRGBA8 0xFFE4C4FF
export blanchedalmond : RGBA8; blanchedalmond = MkRGBA8 0xFFEBCDFF
export cornsilk       : RGBA8; cornsilk       = MkRGBA8 0xFFF8DCFF

-------------------------------------------------------------------------------
-- White, Gray & Black Colors
export white          : RGBA8; white          = MkRGBA8 0xFFFFFFFF
export snow           : RGBA8; snow           = MkRGBA8 0xFFFAFAFF
export honeydew       : RGBA8; honeydew       = MkRGBA8 0xF0FFF0FF
export mintcream      : RGBA8; mintcream      = MkRGBA8 0xF5FFFAFF
export azure          : RGBA8; azure          = MkRGBA8 0xF0FFFFFF
export ghostwhite     : RGBA8; ghostwhite     = MkRGBA8 0xF8F8FFFF
export whitesmoke     : RGBA8; whitesmoke     = MkRGBA8 0xF5F5F5FF
export seashell       : RGBA8; seashell       = MkRGBA8 0xFFF5EEFF
export beige          : RGBA8; beige          = MkRGBA8 0xF5F5DCFF
export oldlace        : RGBA8; oldlace        = MkRGBA8 0xFDF5E6FF
export floralwhite    : RGBA8; floralwhite    = MkRGBA8 0xFFFAF0FF
export ivory          : RGBA8; ivory          = MkRGBA8 0xFFFFF0FF
export antiquewhite   : RGBA8; antiquewhite   = MkRGBA8 0xFAEBD7FF
export linen          : RGBA8; linen          = MkRGBA8 0xFAF0E6FF
export lavenderblush  : RGBA8; lavenderblush  = MkRGBA8 0xFFF0F5FF
export mistyrose      : RGBA8; mistyrose      = MkRGBA8 0xFFE4E1FF
export gainsboro      : RGBA8; gainsboro      = MkRGBA8 0xDCDCDCFF
export lightgray      : RGBA8; lightgray      = MkRGBA8 0xD3D3D3FF
export lightgrey      : RGBA8; lightgrey      = MkRGBA8 0xD3D3D3FF
export silver         : RGBA8; silver         = MkRGBA8 0xC0C0C0FF
export darkgray       : RGBA8; darkgray       = MkRGBA8 0xA9A9A9FF
export darkgrey       : RGBA8; darkgrey       = MkRGBA8 0xA9A9A9FF
export gray           : RGBA8; gray           = MkRGBA8 0x808080FF
export grey           : RGBA8; grey           = MkRGBA8 0x808080FF
export dimgray        : RGBA8; dimgray        = MkRGBA8 0x696969FF
export dimgrey        : RGBA8; dimgrey        = MkRGBA8 0x696969FF
export lightslategray : RGBA8; lightslategray = MkRGBA8 0x778899FF
export lightslategrey : RGBA8; lightslategrey = MkRGBA8 0x778899FF
export slategray      : RGBA8; slategray      = MkRGBA8 0x708090FF
export slategrey      : RGBA8; slategrey      = MkRGBA8 0x708090FF
export darkslategray  : RGBA8; darkslategray  = MkRGBA8 0x2F4F4FFF
export darkslategrey  : RGBA8; darkslategrey  = MkRGBA8 0x2F4F4FFF
export black          : RGBA8; black          = MkRGBA8 0x000000FF

-------------------------------------------------------------------------------
-- Other Keywords
export transparent    : RGBA8; transparent    = MkRGBA8 0x00000000


