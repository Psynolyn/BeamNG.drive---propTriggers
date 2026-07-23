# BeamNG.drive - propTriggers

`propTriggers` is a custom Lua extension for BeamNG.drive that vastly improves vehicle interiors by allowing modders to bind interactive click triggers directly to animated vehicle props. 

Traditionally, BeamNG triggers (`vehicleTriggers`) are bound to static JBeam nodes. If you have an animated prop (like an indicator stalk, gear shifter, or switch), a node-based trigger will stay behind when the prop moves. `propTriggers` solves this by attaching triggers directly to the live 3D mesh of the prop, perfectly following its animation without requiring any complex animation curves.

## Features

- **Live Prop Inheritance:** Triggers extract the real-time world transform (position & rotation) of any `targetProp` and follow it seamlessly.
- **Mesh Triggers:** Adds a brand new `mesh` trigger type. You can use a `.obj` file to define the exact 3D shape of your clickable area instead of relying on basic boxes or spheres.
- **Native UI Integration:** Fully supports the vanilla BeamNG `ui_bindingsLegend`. When a player hovers over your custom trigger, the action title and keyboard shortcut appear in the bottom-left corner exactly like a native game trigger.
- **Dynamic Event Links:** Features a `propTriggerEventLinks` system that works identically to `triggerEventLinks2`, routing custom string IDs straight to your `vehicle_name.interaction.json` logic.
- **Transform Offsets:** Easily offset the clickable area relative to the prop using `baseTranslation` and `baseRotation`.
- **Proximity Fading:** Trigger debug visualization gracefully fades in and out based on camera proximity and mouse hover.

---

## Installation

Simply copy `propTriggers.lua` into your mod's folder structure at the following path:
`lua/ge/extensions/propTriggers.lua`

The game will automatically load the extension when the vehicle spawns.

---

## JBeam Usage

You configure prop triggers in your vehicle's main `.jbeam` file, very similarly to standard triggers.

### 1. Mesh Trigger Example

This example demonstrates how to create a trigger that uses a custom `.obj` mesh for its collision area, and binds directly to a moving prop (`steering_wheel`).

```json
"propTriggers":[
    ["id", "targetProp", "type", "size", "meshName", "baseTranslation", "baseRotation", "action"],
    
    // "cruisecontroll_+" is the trigger ID.
    // "steering_wheel" is the name of the mesh defined in the "props" section.
    // {"x":90, "y":0, "z":45} applies a local rotation offset.
    // {"x":0.1, "y":0, "z":0} applies a local translation offset along the newly rotated axes.
    ["cruisecontroll_+", "steering_wheel", "mesh", {"x":1, "y":1, "z":1}, "vehicles/your_vehicle/mesh/trigger_box.obj", {"x":0.1, "y":0, "z":0}, {"x":90, "y":0, "z":45}, ""],
],
```

### 2. Standard Box Trigger Example

You can still use traditional `idRef`, `idX`, and `idY` nodes if you want to create static box/sphere triggers with this system.

```json
"propTriggers":[
    ["id", "idRef:", "idX:", "idY:", "type", "size", "baseRotation", "rotation", "translation", "baseTranslation", "action"],
    ["toggle_switch", "sw1","sw3","sw2", "box", {"x":0.015, "y":0.014, "z":0.009}, {"x":284, "y":358, "z":0.6}, {"x":0, "y":0, "z":0}, {"x":0, "y":0, "z":0}, {"x":0.20, "y":0.16, "z":0.07}, ""],
],
```

### 3. Binding to Input Actions

To make your triggers actually *do* something and display native UI text, you map them to your `vehicle_name.interaction.json` using the `propTriggerEventLinks` section.

```json
"propTriggerEventLinks":[
    ["triggerId", "triggerInput", "inputAction"],
    
    // Maps the "cruisecontroll_+" trigger to the "cruisecontroll_+" action.
    // When clicked, it fires the onDown event defined in vehicle_name.interaction.json
    // The UI will automatically extract the action's "title" and shortcut binding to display on hover.
    ["cruisecontroll_+", "action0", "cruisecontroll_+"],
],
```

---

