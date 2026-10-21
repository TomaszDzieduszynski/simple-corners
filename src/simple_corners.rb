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
  VERSION = '1.1.12'.freeze
  CREDITS = 'Vibecoded by Tomasz "bzqp" Dzieduszyński using Claude Opus 5.5, 2026'.freeze

  unless file_loaded?(__FILE__)
    loader = File.join(File.dirname(__FILE__).dup.force_encoding('UTF-8'), 'simple_corners', 'main')
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
