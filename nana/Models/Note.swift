//
//  Note.swift
//  nana
//
//  Created by Emmett McDow on 2/28/25.
//

import Foundation

struct Note {
    var id: Int
    var created: Date
    var modified: Date
    var relpath: String // TODO: Get back to this can this be a FilePath? Not in scope?
    var content: String
}
