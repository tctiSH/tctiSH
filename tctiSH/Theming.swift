//
//  Theming.swift
//  tctiSH
//
//  Created by Kate Temkin on 9/2/22.
//  Copyright © 2022 Kate Temkin. All rights reserved.
//

import Foundation

private let xrdbSolarizedDark = """
    #define Ansi_0_Color #073642
    #define Ansi_1_Color #dc322f
    #define Ansi_10_Color #586e75
    #define Ansi_11_Color #657b83
    #define Ansi_12_Color #839496
    #define Ansi_13_Color #6c71c4
    #define Ansi_14_Color #93a1a1
    #define Ansi_15_Color #fdf6e3
    #define Ansi_2_Color #859900
    #define Ansi_3_Color #b58900
    #define Ansi_4_Color #268bd2
    #define Ansi_5_Color #d33682
    #define Ansi_6_Color #2aa198
    #define Ansi_7_Color #eee8d5
    #define Ansi_8_Color #002b36
    #define Ansi_9_Color #cb4b16
    #define Background_Color #002b36
    #define Badge_Color #ff2600
    #define Bold_Color #93a1a1
    #define Cursor_Color #839496
    #define Cursor_Guide_Color #b3ecff
    #define Cursor_Text_Color #073642
    #define Foreground_Color #839496
    #define Link_Color #005cbb
    #define Selected_Text_Color #93a1a1
    #define Selection_Color #073642
    """

class DefaultThemes {
   
    //
    // Internal, private themeing.
    //
    
    
    /// Default, Solarized Dark theme.
    public static let solzariedDark = ThemeColor.fromXrdb (title: "Solarized Dark", xrdb: xrdbSolarizedDark)!
    
}
