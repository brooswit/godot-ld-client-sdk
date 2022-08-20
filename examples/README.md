# LaunchDarkly sample Godot (client-side) application

I've modified the Truck Town example that comes with Godot to demonstrate how LaunchDarkly's SDK works. Below, you'll find instructions on how to get started.

The LaunchDarkly client-side SDK for Node.js is designed primarily for use in single-user contexts such as client-side game clients. It is not intended for multi-user contexts, such as headless game servers.

## Getting started

Follow these instructions before opening this project in Godot:

1. Move `addons` folder from parent directory into this directory.

2. Edit `car_select.gd` and set the value of `LAUNCHDARKLY_MOBILE_KEY` to your LaunchDarkly Mobile Key. 

3. Create the following flags in your LaunchDarkly project:

- A numeric flag with the key `steer-speed`. A reccomended defalt value for this flag should be `1.5`
- A numeric flag with the key `engine-force`. A reccomended defalt value for this flag should be `40`
- A numeric flag with the key `steer-limit`. A reccomended defalt value for this flag should be `0.4`

4. Run the game!

You can now control the stats of your vehicle in realtime using LaunchDarkly.
