//
//  MetarMateWidgetBundle.swift
//  MetarMateWidget
//
//  Created by jquayle on 3/3/26.
//

import WidgetKit
import SwiftUI

@main
struct MetarMateWidgetBundle: WidgetBundle {
    var body: some Widget {
        MetarMateLockScreenCircular()
        MetarMateLockScreenRectangular()
        MetarMateLockScreenInline()
        MetarMateHomeSmall()
    }
}
