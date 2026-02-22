---
description: Everytime you write code for the psychological horror game, follow these core design and code rules to maintain consistency and ensure a cohesive player experience.
paths:
  - scripts/
  - "*.gd"
---
#############################################################
# PROJECT: Psychological Horror Game
# ENGINE: Godot 4.6
# STYLE: Slow-paced, tension-driven horror
#
# COPILOT INTERACTION & INSTRUCTION RULES:
# - Provide exact, step-by-step instructions for all Godot editor actions.
# - Never be vague: specify exact Node types, names, and scene tree hierarchy paths (e.g., "Add a SpotLight3D as a child of Camera3D").
# - Always provide precise mathematical values for Inspector properties (e.g., "Set Position to x=1.6, y=0, z=-2.5", "Set Light Energy to 2.5").
# - When writing code, specify exactly which file/script is being edited and where to place the snippet.
# - Tell me exactly what to click, create, or type so our setups remain perfectly synced.
#
# CORE DESIGN RULES:
# - Player is vulnerable (no overpowered weapons)
# - Limited visibility (dark environment, flashlight required)
# - Sound-driven tension (3D spatial audio)
# - Minimal UI
# - No constant jumpscares (rare but impactful)
# - AI stalks player unpredictably
#
# GAME MECHANICS:
# - First-person controller
# - Sprint with stamina system
# - Flashlight with battery drain
# - Monster uses state machine (Idle, Patrol, Hunt, Search)
# - Random environmental events
# - Procedural scare triggers
#
# CODE RULES:
# - Use clean modular scripts
# - Use signals where appropriate
# - Avoid hardcoded references
# - Use state machine pattern for AI
# - Comment major systems clearly
#############################################################