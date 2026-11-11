# Advanced puzzle setup guide

Run `advanced-puzzle-setup.sql` in the Supabase SQL Editor after the existing `admin-puzzle-setup.sql` migration. The new puzzle formats then appear in the Admin Portal.

For every format, fill in the normal room, title, instructions, rewards and hints. The **Correct answer** field stores the solution. For interactive formats, enter valid JSON (including square brackets and quotation marks). The **Interactive puzzle settings (JSON)** field controls what the player sees.

## Puzzle types and examples

### 3×3 button sequence
- Correct answer: `[2,5,1,9]` (button labels 1–9, in order).
- Settings: `{}`
- Tell players how to derive the sequence in the instructions or hints.

### Pager-generated code
- Correct answer: leave blank.
- Settings: `{}`
- The player generating the code must have an inventory item whose `item_id` is exactly `pager`.
- The generated six-digit code expires after two minutes, is single-use, and must be entered by a different player.

### Memory sequence
- Correct answer: `["red","blue","green","yellow"]`
- Settings: `{"displaySequence":["red","blue","green","yellow"],"showForMs":5000}`
- The sequence is displayed for five seconds by default. Players then type it in the same order. Use `showForMs` to change the display duration.

### Combination dials
- Correct answer: `[3,7,2]`
- Settings: `{"dials":[{"label":"North","min":0,"max":9},{"label":"East","min":0,"max":9},{"label":"West","min":0,"max":9}]}`
- Each dial is a number selector. The answer array must follow the dial order.

### Hidden message
- Correct answer: `"THE KEY IS UNDER THE TABLE"` (enter the message without JSON quotation marks).
- Settings: `{"requiredItemId":"uv_torch","hiddenMessage":"THE KEY IS UNDER THE TABLE"}`
- The message is returned to players only if they have the required inventory item. Change `uv_torch` to the item ID you use.

### Picture reconstruction
- Correct answer: `[1,2,3,4,5,6,7,8,9]`
- Settings: `{"imageUrl":"https://your-public-image-url/image.jpg","pieces":9}`
- Use a publicly accessible image URL. Players swap the shuffled image tiles until they are in numerical/original order. The current board uses a 3×3 grid.

### Circuit connection
- Correct answer: `["A-B","C-D"]`
- Settings: `{"connections":["A-B","A-C","B-C","B-D","C-D"]}`
- Players select the wires they believe complete the circuit. Keep the correct connection labels in the answer array in alphabetical order.

### Maze navigation
- Correct answer: `[4,4]` (finish coordinate, zero-based).
- Settings: `{"width":5,"height":5,"start":[0,0],"finish":[4,4],"walls":[[1,0],[1,1],[3,2]]}`
- Coordinates are `[x,y]`, starting at zero. Wall coordinates are impassable. The answer is the finish coordinate.

### Symbol alignment
- Correct answer: `["☾","■","♝"]`
- Settings: `{"rings":[["☀","☾","★"],["▲","■","●"],["♜","♞","♝"]]}`
- The answer array gives the selected symbol for each ring, in order.

## Notes
- Use JSON exactly: invalid JSON in the settings field will prevent saving.
- Interactive puzzle solutions are checked by Supabase; the browser does not receive the answer field.
- The Pager flow requires a separate player account holding the Pager item. Add that item to the player's inventory with `item_id = 'pager'`.
