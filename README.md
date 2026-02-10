# AbilityAlert

A World of Warcraft addon that notifies your friend via whisper when you use specific abilities.

## Installation

1. Copy the `AbilityAlert` folder to your WoW addons directory:
   - `World of Warcraft\_retail_\Interface\AddOns\`
   
2. Both you and your friend need to install this addon

3. Restart WoW or type `/reload` in-game

## Setup

1. Set your friend's character name:
   ```
   /aa friend CharacterName
   ```

2. Add abilities to track:
   - Hover over an ability in your spellbook or action bar
   - Type `/aa add`
   
3. Test the connection:
   ```
   /aa test
   ```

## Commands

- `/aa help` - Show all commands
- `/aa friend <name>` - Set your friend's character name
- `/aa add` - Add the ability you're hovering over
- `/aa list` - List all tracked abilities
- `/aa remove <spellID>` - Remove an ability by its spell ID
- `/aa clear` - Clear all tracked abilities
- `/aa toggle` - Enable/disable notifications
- `/aa test` - Send a test message

## How It Works

1. When you cast a tracked ability, the addon sends a whisper to your friend
2. Your friend's addon receives the whisper and displays it prominently
3. A sound plays to alert them

## Requirements

- You and your friend must be on the same realm (for whispers)
- Both players need this addon installed
- You must be able to whisper each other

## Example Usage

You're playing a tank and want to alert your healer when you use big defensive cooldowns:

1. Set friend: `/aa friend HealerName`
2. Hover over "Shield Wall" and type `/aa add`
3. Hover over "Last Stand" and type `/aa add`
4. Now whenever you use these abilities, your healer gets an instant notification!

## Notes

- The addon saves your settings between sessions
- You can track as many abilities as you want
- Messages are sent as regular whispers
