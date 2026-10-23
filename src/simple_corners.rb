# encoding: UTF-8
# Simple Corners - SketchUp extension loader.
#
# Round Edges, Round Edges Mitred and Bevel Edges tools for edges of solids.
# Vibecoded by Tomasz "bzqp" Dzieduszyński using Claude Opus 5.5, 2026.
# Copyright (C) 2026 Tomasz "bzqp" Dzieduszyński
# SPDX-License-Identifier: GPL-3.0-or-later
# License: GNU General Public License v3 or later, see simple_corners/LICENSE.txt.

require 'sketchup.rb'
require 'extensions.rb'

module SimpleCorners
  VERSION = '1.2.1'.freeze
  CREDITS = 'Vibecoded by Tomasz "bzqp" Dzieduszyński using Claude Opus 5.5, 2026'.freeze

  unless file_loaded?(__FILE__)
    # __FILE__ has the wrong encoding on Windows with non-English folder
    # names: copy it and mark it as UTF-8 before using it as a path.
    file = __FILE__.dup
    file.force_encoding('UTF-8') if file.respond_to?(:force_encoding)
    loader = File.join(File.dirname(file), 'simple_corners', 'main')
    ext = SketchupExtension.new('Simple Corners', loader)
    ext.description = 'Round Edges, Round Edges Mitred and Bevel Edges tools: round or ' \
                      "bevel the edges of solids, with smooth or sharp corners. #{CREDITS}. " \
                      'License: GNU GPL v3 or later.'
    ext.version = VERSION
    ext.creator = 'Tomasz "bzqp" Dzieduszyński'
    ext.copyright = "#{CREDITS}. GNU GPL v3 or later"
    EXTENSION = ext
    Sketchup.register_extension(ext, true)
    file_loaded(__FILE__)
  end
end
