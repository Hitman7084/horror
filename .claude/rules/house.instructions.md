---
description: Describe when these instructions should be loaded
paths:
  - **/.gd
  - "*.gd"
  - "*.tscn"
  - "*.ts"
---
#############################################################
# CREATE HORROR HOUSE ENVIRONMENT (DETERMINISTIC BUILD)
# ENGINE: Godot 4.6
#
# DO NOT RENAME NODES.
# DO NOT MODIFY TRANSFORMS.
# DO NOT ADD EXTRA NODES.
#
#############################################################

############################
# 1️⃣ HOUSE ROOT STRUCTURE
############################

# Under Main node, create:

# House (Node3D)
# ├── FloorMesh (MeshInstance3D)
# ├── FloorCollision (CollisionShape3D)
# ├── Walls (Node3D)
# │    ├── Wall_North (StaticBody3D)
# │    ├── Wall_South (StaticBody3D)
# │    ├── Wall_East  (StaticBody3D)
# │    ├── Wall_West  (StaticBody3D)
# │
# ├── Ceiling (StaticBody3D)
# ├── Doorway (StaticBody3D)
# ├── LightningManager (Node3D)
#
# All walls must contain:
# - MeshInstance3D
# - CollisionShape3D

############################
# 2️⃣ EXACT HOUSE DIMENSIONS
############################

# House size: 12m x 12m

# FloorMesh:
# Mesh: PlaneMesh
# Size: 12 x 12
# Position: (0, 0, 0)

# FloorCollision:
# Shape: BoxShape3D
# Size: (6, 0.1, 6)
# Position: (0, 0, 0)

############################
# 3️⃣ WALLS (HEIGHT = 3 METERS)
############################

# All walls:
# Height = 3
# Thickness = 0.2

# North Wall:
# Position: (0, 1.5, -6)
# Box Size: (6, 1.5, 0.1)

# South Wall:
# Position: (0, 1.5, 6)
# Box Size: (6, 1.5, 0.1)

# East Wall:
# Position: (6, 1.5, 0)
# Box Size: (0.1, 1.5, 6)

# West Wall:
# Position: (-6, 1.5, 0)
# Box Size: (0.1, 1.5, 6)

############################
# 4️⃣ DOORWAY (OPENING ON SOUTH WALL)
############################

# Remove center section of South Wall.
# Instead create Doorway_Left and Doorway_Right.

# Doorway width: 2 meters
# Door height: 2.5 meters

# Doorway_Left:
# Position: (-2, 1.25, 6)
# Size: (2, 1.25, 0.1)

# Doorway_Right:
# Position: (2, 1.25, 6)
# Size: (2, 1.25, 0.1)

############################
# 5️⃣ CEILING
############################

# Position: (0, 3, 0)
# Box Size: (6, 0.1, 6)

############################
# 6️⃣ GLOBAL LIGHTING SETTINGS
############################

# Add DirectionalLight3D to Main.
# Name: MoonLight

# Rotation:
# X = -45 degrees
# Y = 30 degrees
# Z = 0

# Light Energy = 0.5
# Light Color = Slight blue (#AABFFF)
# Shadows Enabled = True

############################
# 7️⃣ INTERIOR LIGHT
############################

# Add OmniLight3D inside House.
# Name: FlickerLight

# Position: (0, 2.5, 0)
# Energy: 1.2
# Range: 6
# Color: Warm yellow (#FFD8A0)
# Shadows Enabled = True

############################
# 8️⃣ LIGHT FLICKER SYSTEM
############################

# Create script for FlickerLight:
#
# - Every 3 to 8 seconds:
#   Random chance 40% to flicker
#
# Flicker behavior:
# - Rapid energy changes between 0.2 and 1.2
# - Duration 0.2 to 0.5 seconds
# - Return to 1.2 energy after flicker
#
# Use Timer node.
# Do NOT stack flickers.

############################
# 9️⃣ LIGHTNING STORM EFFECT
############################

# In LightningManager create:

# StormLight (DirectionalLight3D)
# Default Energy = 0
# Color = White
# Shadows Enabled = True

# Lightning System:
# Every 20 to 40 seconds:
#   30% chance to trigger lightning
#
# Lightning Flash:
#   StormLight energy = 6.0
#   Duration = 0.15 seconds
#   Then fade to 0 over 0.3 seconds
#
# During lightning:
#   Briefly increase WorldEnvironment ambient light to 0.6
#   After 0.3 seconds return to 0.2
#
# Add Thunder sound 0.5 to 1.2 seconds after flash.
#
# Thunder volume = -8db
# Must not overlap previous thunder.

#############################################################
# END SPEC
#############################################################