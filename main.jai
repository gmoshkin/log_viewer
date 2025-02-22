EXE_NAME :: "log_viewer";

/*

TODO:

- anchors??
- log parsing + semantic highlighting
- BUG scroll bar almost non-existent
- minimap
- filterring? I'm not sure yet what I want/need
- different panes for different ui elements
- status bar

*/

main :: () {
    Profile();

    context.logger = my_logger;
    context.print_style.struct_printer = my_struct_printer;

    #if OS == .WINDOWS {
        // In order to have a hope of waiting a reasonable amount of time,
        // we need to do this stupid thing. Probably we should use CreateWaitableTimer
        // and SetWaitableTimer, but we need that for every platform.
        Windows :: #import "Windows";
        Windows.timeBeginPeriod(1);
    }

    window_size = .{ 1300, 1000 };
    window = create_window(xx window_size.x, xx window_size.y, EXE_NAME,
                           background_color_rgb = .[.1, .1, .1],
                           wanted_msaa = WANTED_MSAA);

    exe_path := System.get_path_of_running_executable();
    exe_dir := path_strip_filename(exe_path);
    assets_directory = sprint("%/assets", exe_dir);

    Profile();
    load_text_buffer_data();
    Profile();

    reload_main_font();
    debug_font = Simp.get_font_at_size(assets_directory, "Codetta-Regular.ttf", 14);

    msaa := Simp.prepare_window(window, wanted_msaa = WANTED_MSAA);
    Simp.set_render_target(window);

    should_quit := false;
    while !should_quit {
        should_quit = update_and_draw_frame();

        reset_temporary_storage();

        sleep_milliseconds(xx (1000.0 / 60.0));
    }
}

//
// global state
//

window: Window_Type;
window_size: Vector2;
mouse: Vector2;
mouse_last_frame: Vector2;
mouse_at_click: Vector2;
window_rect: Rectangle;

assets_directory: string;

frame_counter := 1;
redraw_needed := false;

main_font: Simp.Dynamic_Font;
main_font_size := 14;
main_font_line_height: s64;
main_font_mono_width: s64;

debug_font: Simp.Dynamic_Font;
debug_text_color := #run hex_color("dddddd");

text_buffer_data: string;
text_buffer_line_offsets: [..] s64;

text_pane_rect: Rectangle;
left_column_rect: Rectangle;

scroll_rows := 0.0;
scroll_columns := 0;
scroll_rows_at_click := 0.0;

draggin_scroll_bar := false;
scroll_bar_rect: Rectangle;
scroll_bar_pad := 1;
scroll_bar_slider_color := #run hex_color("d0d0d0");
scroll_bar_anchor_min_width := 1.7;

anchor_button_active_color  := #run hex_color("4050d0");
anchor_button_hover_color   := #run hex_color("404040");
anchor_line_highlight_color := #run hex_color("404040");
anchors: [..] Anchor;
Anchor :: struct {
    line_index: s64;
}
hovered_anchor_button_line: s64 = -1;
hovered_scroll_bar_anchor_index: s64 = -1;

//
// main update and draw proc
//

update_and_draw_frame :: () -> bool {
    t0 := seconds_since_init();

    should_quit := false;

    Input.update_window_events();

    for Input.get_window_resizes() {
        assert(it.window == window);
        window_size.x = xx it.width;
        window_size.y = xx it.height;
        log("window_size: %", window_size);

        redraw_needed = true;
    }

    {
        x, y, ok := get_mouse_pointer_position(window, true);
        if ok {
            mouse.x = xx x;
            mouse.y = xx y;
        }
    }
    defer mouse_last_frame = mouse;

    for Input.events_this_frame {
        modifiers: enum_flags { NONE :: 0x00; CTRL :: 0x01; SHIFT :: 0x02; ALT :: 0x04; };
        if key_is_down(.CTRL)  modifiers |= .CTRL;
        if key_is_down(.SHIFT) modifiers |= .SHIFT;
        if key_is_down(.ALT)   modifiers |= .ALT;

        // if !it.repeat {
        //     if it.type == .MOUSE_WHEEL
        //         log("% % %", it.type, it.wheel_delta, it.touch_type);
        //     else
        //         log("%", it);
        // }

        if it.type == .QUIT then should_quit = true;

        else if it.key_pressed && it.key_code == .F4 && it.shift_pressed {
            debug_break();
        }

        else if it.key_pressed && it.key_code == .F4 && it.alt_pressed {
            should_quit = true;
        }

        else if it.key_code == .MOUSE_BUTTON_LEFT && it.key_pressed {
            redraw_needed = true;
            mouse_at_click = mouse;
        }

        // modules/Input doesn't set it.ctrl_pressed for MOUSE_WHEEL :(
        else if it.type == .MOUSE_WHEEL && modifiers == .CTRL && !draggin_scroll_bar {
            ofs := it.wheel_delta / it.typical_wheel_delta;

            main_font_size += ofs;
            main_font_size = max(main_font_size, 1);
            reload_main_font();
            redraw_needed = true;
        }

        // modules/Input doesn't set it.ctrl_pressed for MOUSE_WHEEL :(
        else if it.type == .MOUSE_WHEEL && modifiers == .SHIFT && !draggin_scroll_bar {
            ofs := it.wheel_delta / it.typical_wheel_delta;

            scroll_columns += -ofs * 8;
            scroll_columns = max(scroll_columns, 0);
            redraw_needed = true;
        }

        else if it.type == .MOUSE_WHEEL && !modifiers && !draggin_scroll_bar {
            ofs := it.wheel_delta / cast(float) it.typical_wheel_delta;
            scroll_rows += -ofs * 3;
            redraw_needed = true;
        }
    }

    absolute_top := cast(s32) (window_size.y);
    absolute_bottom := cast(s32) (0);
    absolute_left := cast(s32) (0);
    absolute_right := cast(s32) (window_size.x);
    absolute_mid_x := (absolute_left + absolute_right) / 2;
    absolute_mid_y := (absolute_bottom + absolute_top) / 2;
    window_rect.top = xx window_size.y;
    window_rect.left = 0;
    window_rect.width = xx window_size.x;
    window_rect.height = xx window_size.y;

    // scroll bar info
    {
        using scroll_bar_rect;
        width  = 16;
        left   = absolute_right - width;
        top    = absolute_top;
        height = xx window_size.y;
    }

    //
    // text pane info
    //
    {
        using text_pane_rect;
        left   = absolute_left + 40;
        left = max(left, xx (main_font_line_height * 3));
        top    = absolute_top;
        width  = xx (window_size.x - 40 - 100);
        height = xx window_size.y;
    }
    total_line_count := text_buffer_line_offsets.count;
    text_pane_row_count := text_pane_rect.height / main_font_line_height;
    // clamp update scroll_rows based on text_pane height.
    // Not doing this when handling the input event, because text pane height is not known at that point
    scroll_rows = max(scroll_rows, -text_pane_row_count / 2.0);
    scroll_rows = min(scroll_rows, total_line_count - text_pane_row_count / 2.0);

    // XXX what's the english name for поле?
    {
        using left_column_rect;
        left   = absolute_left;
        top    = absolute_top;
        width  = text_pane_rect.left - absolute_left;
        height = xx window_size.y;
    }

    //
    // scroll bar info
    //
    zoom_ratio := text_pane_row_count / cast(float) total_line_count;
    zoom_ratio = min(zoom_ratio, 1); // XXX looks sus
    scroll_bar_slider_effective_height := scroll_bar_rect.height * zoom_ratio;
    scroll_bar_slider_visible_height := max(scroll_bar_slider_effective_height, 20);
    lines_per_scroll_bar_pixel := text_pane_row_count / scroll_bar_slider_effective_height;

    //
    // drag scroll bar
    //
    if draggin_scroll_bar {
        mouse_moved := mouse.y - mouse_at_click.y;
        scroll_rows = scroll_rows_at_click - xx (mouse_moved * lines_per_scroll_bar_pixel);
        scroll_rows = max(scroll_rows, 0);
        scroll_rows = min(scroll_rows, xx total_line_count - text_pane_row_count / 2.0);

        if !key_is_down(.MOUSE_BUTTON_LEFT) draggin_scroll_bar = false;

        if mouse != mouse_last_frame then redraw_needed = true;
    }

    //
    // update anchor buttons
    //
    {
        if !draggin_scroll_bar && axis_aligned_rectangle_contains(left_column_rect, mouse) {
            hover_line_index := screen_position_to_row_index(left_column_rect, mouse.y);
            if hover_line_index >= 0 {
                if hover_line_index != hovered_anchor_button_line {
                    redraw_needed = true;
                    hovered_anchor_button_line = hover_line_index;
                }

                if is_click(.MOUSE_BUTTON_LEFT) {
                    found := false;
                    for anchors {
                        if it.line_index != hover_line_index continue;
                        remove it;
                        found = true;
                        break;
                    }

                    if !found {
                        array_add(*anchors, .{ hover_line_index });
                    }
                }
            } else {
                hovered_anchor_button_line = -1;
                redraw_needed = true;
            }
        }

        if hovered_anchor_button_line != -1 && !axis_aligned_rectangle_contains(left_column_rect, mouse) {
            hovered_anchor_button_line = -1;
            redraw_needed = true;
        }
    }

    //
    // update scroll bar anchors
    //
    if !draggin_scroll_bar && axis_aligned_rectangle_contains(scroll_bar_rect, mouse) {
        mouse_y_in_rect := mouse.y - bottom(scroll_bar_rect);
        anchor_index := do_scroll_bar_anchors(scroll_bar_rect, .GET_HOVER, mouse_y_in_rect);

        if anchor_index != -1 && is_click(.MOUSE_BUTTON_LEFT) {
            anchor := anchors[anchor_index];
            scroll_rows = xx (anchor.line_index - text_pane_row_count / 2);
        }

        if anchor_index != hovered_scroll_bar_anchor_index {
            hovered_scroll_bar_anchor_index = anchor_index;
            redraw_needed = true;
        }
    }

    // I'm sleepy but this doesn't work???
    if hovered_scroll_bar_anchor_index != -1 && !axis_aligned_rectangle_contains(scroll_bar_rect, mouse) {
        hovered_scroll_bar_anchor_index = -1;
        redraw_needed = true;
    }

    ////////////////////////////////////////////////////////////////////////////
    // TEMPORARY!!!
    if mouse_last_frame != mouse then redraw_needed = true;

    if !redraw_needed return should_quit;
    redraw_needed = false;

    //
    // render start
    //

    Simp.update_window(window);
    base_color := hex_color("191919");
    Simp.clear_render_target(base_color.x, base_color.y, base_color.z, 1);

    Simp.set_shader_for_color();

    // draw text pane
    {
        profile_t0 = seconds_since_init();
        draw_text_pane(text_pane_rect);
        Profile();
    }

    //
    // draw line anchors
    //
    {
        rect := *left_column_rect;
        x_tweak := -3;
        y_tweak := 0;

        // hovered anchor button
        if hovered_anchor_button_line != -1 {
            pad := 1;
            color := anchor_button_hover_color;
            h := main_font_line_height - 2 * pad;
            w := h;
            x := rect.left + rect.width - w - pad + x_tweak;

            row_index := hovered_anchor_button_line - scroll_rows;
            y_line := rect.top - (row_index + 1) * main_font_line_height + y_tweak;
            y := y_line + pad;

            // draw_axis_aligned_rectangle(xx (rect.left + rect.width - main_font_line_height),
            //                             xx y_line,
            //                             xx main_font_line_height, xx main_font_line_height, hex_color("000000"));
            draw_hollow_axis_aligned_rectangle(xx x, xx y, xx w, xx h, border = 2, color);
        }

        // active anchor buttons
        {
            color := anchor_button_active_color;
            pad := 4;
            h := main_font_line_height - 2 * pad;
            w := h;
            x := rect.left + rect.width - w - pad + x_tweak;
            for anchors {
                row_index := it.line_index - scroll_rows;
                if row_index < 0 continue;
                if row_index > xx (rect.height * main_font_line_height) continue;

                y_line := rect.top - (row_index + 1) * main_font_line_height + y_tweak;
                y := y_line + pad;
                draw_axis_aligned_rectangle(xx x, xx y, xx w, xx h, color);
            }
        }
    }

    // draw scroll bar & update scroll bar slider
    {
        rect := *scroll_bar_rect;
        w := rect.width - scroll_bar_pad * 2;

        h := scroll_bar_slider_visible_height;

        x := rect.left + scroll_bar_pad;

        scroll_y := scroll_rows / lines_per_scroll_bar_pixel;
        // FIXME: this is computed for the effective size, as a result the
        // scrollbar doesn't fit nicely at the bottom of the screen... So frustrating!!!
        y := rect.top - scroll_y - h;

        // update scroll bar slider
        color := scroll_bar_slider_color;
        if is_click(.MOUSE_BUTTON_LEFT) && axis_aligned_rectangle_contains(xx x, xx y, xx w, xx h, mouse) {
            draggin_scroll_bar = true;
            redraw_needed = true;
            scroll_rows_at_click = scroll_rows;
        }

        draw_axis_aligned_rectangle(xx x, y, xx w, h, color);

        // draw scroll bar anchors
        mouse_y_in_rect := mouse.y - bottom(scroll_bar_rect);
        do_scroll_bar_anchors(scroll_bar_rect, .DRAW, mouse_y_in_rect);
    }

    // frame counter
    {
        elapsed := seconds_since_init() - t0;
        font := *debug_font;
        h := font.character_height;
        w_text := Simp.prepare_text(font, tprint("% %", frame_counter, fmt(elapsed, 6)));

        pad := 4;
        x := absolute_left + pad;
        y_tweak := 1;
        y := absolute_top - h - pad - y_tweak;
        Simp.draw_prepared_text(font, xx x, xx y);
    }

    // debuggin
    {
        /*
        rect := window_rect;
        font := *debug_font;
        x := right(window_rect) - 300;
        y := window_rect.top - 4;

        builder: String_Builder; builder.allocator = temp;
        print(*builder, "scroll_rows: %\n", scroll_rows);
        print(*builder, "mouse_from_top: %\n", rect.top - mouse.y);
        print(*builder, "main_font_line_height: %\n", main_font_line_height);

        pane_text := builder_to_string(*builder,, temp);
        draw_simple_text_pane(rect, font, x, y, pane_text, hex_color("ffffff"), hex_color("104060"));
        */
    }

    Simp.swap_buffers(window);
    Profile();
    frame_counter += 1;

    return should_quit;
}

//
// scroll bar stuff
//

do_scroll_bar_anchors :: (rect: Rectangle, mode: enum { DRAW; GET_HOVER; }, target_y: float) -> (index: s64) {
    color := anchor_button_active_color;
    hover_color := hex_color("e0e0e0");

    hover_index := -1;

    pixels_on_scroll_bar_per_text_line := rect.height / cast(float) text_buffer_line_offsets.count;
    x := rect.left;
    w := rect.width;
    h := max(scroll_bar_anchor_min_width, pixels_on_scroll_bar_per_text_line);
    slack := 1.2;
    for anchors {
        y := rect.top - (it.line_index + 1) * pixels_on_scroll_bar_per_text_line;

        hover := (target_y >= y - slack && target_y <= y + h + slack);

        if #complete mode == {
        case .DRAW;
            if hover {
                draw_axis_aligned_rectangle(xx x, y - 1, xx w, 1, hover_color);
                draw_axis_aligned_rectangle(xx x, y + h, xx w, 1, hover_color);
                hover_index = it_index;
            }
            draw_axis_aligned_rectangle(xx x, y, xx w, h, color);

        case .GET_HOVER;
            if hover return it_index;
        }
    }

    return hover_index;
}

//
// text pane stuff
//

draw_text_pane :: (rect: Rectangle) {
    text_color       := hex_color("e0e0e0");
    background_color := hex_color("202020");

    // background
    {
        draw_axis_aligned_rectangle(rect, background_color);
    }


    // sample text
    {
        tail := text_buffer_data;

        h := main_font_line_height;

        text_pad := 4;
        pane_width_in_characters := (rect.width - text_pad) / main_font_mono_width;

        x := rect.left + text_pad;
        y := rect.top - h + scroll_rows * main_font_line_height;
        text_y_tweak := -(main_font.typical_descender + main_font.max_descender) / 2;

        line_index := 0;
        while tail {
            defer line_index += 1;
            found:, line:, tail = split_from_left(tail, #char "\n");

            defer y -= h;
            if y > xx rect.top continue;
            if y < xx (rect.top - rect.height - h) continue;

            if line.count <= scroll_columns
                continue;

            line = advance(line, scroll_columns);
            line.count = min(line.count, pane_width_in_characters);

            w_text := Simp.prepare_text(*main_font, line);
            // This fails for unicode!
            // assert(w_text == main_font_mono_width * line.count);

            // if line_index % 2 == 0
            //     draw_axis_aligned_rectangle(xx x, xx y, xx rect.width, xx main_font_line_height, hex_color("005050"));

            anchored := false;
            for anchors if it.line_index == line_index { anchored = true; break; }
            if anchored {
                w := rect.width;
                h := 2;
                x := rect.left;
                y_tweak := -2;
                y_bottom := y + y_tweak;
                y_top := y + main_font_line_height + y_tweak;
                draw_axis_aligned_rectangle(xx x, xx y_bottom, xx w, 2, anchor_line_highlight_color);
                draw_axis_aligned_rectangle(xx x, xx y_top,    xx w, 2, anchor_line_highlight_color);
            }

            Simp.draw_prepared_text(*main_font, xx x, xx y + text_y_tweak, text_color);
        }

    }

}

screen_position_to_row_index :: (rect: Rectangle, y: float) -> s64 {
    if y > xx rect.top return -1;
    rect_bottom := rect.top - rect.height;
    if y < xx rect_bottom return -1;

    // Am I retarded?
    y_in_rect_from_top := rect.top - y;
    row_index := floor(scroll_rows + y_in_rect_from_top / main_font_line_height);
    return xx row_index;
}

screen_space_rectangle_contains_line_index :: (rect: Rectangle, line_index: s64) -> bool {
    // assumming scroll_rows ~ rect.top and main_font
    row_index := line_index - scroll_rows;
    if row_index < 0 return false;
    if row_index > cast(float) rect.height * main_font_line_height return false;
    return true;
}

//
// text buffer stuff
//

load_text_buffer_data :: () {
    text_buffer_data=, ok := read_entire_file(tprint("%/sample_log.txt", assets_directory));
    // text_buffer_data=, ok := read_entire_file("main.jai");
    assert(ok);

    array_reset(*text_buffer_line_offsets);

    max_line_length := 0;

    tail := text_buffer_data;
    while tail {
        found:, line:, tail = split_from_left(tail, #char "\n");
        array_add(*text_buffer_line_offsets, line.data - text_buffer_data.data);

        max_line_length = max(max_line_length, line.count);
    }

    log("line count: %", text_buffer_line_offsets.count);
    log("max line length: %", max_line_length);
}

//
// font stuff
//

reload_main_font :: () {
    font_file_name :: "Codetta-Regular.ttf";
    log("loading '%' at size %", font_file_name, main_font_size);
    main_font = Simp.get_font_at_size(assets_directory, font_file_name, main_font_size);
    main_font_line_height = xx (main_font.character_height - main_font.typical_descender);
    text_width := Simp.prepare_text(*main_font, "abc");
    main_font_mono_width = text_width / 3;
}

//
// ui primitives
//

draw_simple_text_pane :: (rect: Rectangle, font: *Simp.Dynamic_Font, left: s64, top: s64, text: string, text_color: Vector4, background_color: Vector4) {
    h := font.character_height;
    text_y_tweak := -(font.typical_descender + font.max_descender) / 2;
    x_pad := text_y_tweak;

    text_w_max := 0;
    line_count := 0;
    tail := text;
    while tail {
        found:, line:, tail = split_from_left(tail, #char "\n");
        line_count += 1;
        text_w := Simp.prepare_text(font, line);
        text_w_max = max(text_w, text_w_max);
    }

    x := rect.left + left;
    y := bottom(rect) + top;

    {
        X := x - x_pad;
        H := h * line_count;
        Y := y - H + 1;
        W := text_w_max + x_pad * 2;
        draw_axis_aligned_rectangle(xx X, xx Y, xx W, xx H, background_color);
    }

    tail = text;
    for 1..line_count {
        y -= h;
        found:, line:, tail = split_from_left(tail, #char "\n");
        Simp.draw_text(font, xx x, xx y + text_y_tweak, line, text_color);
    }
}

//
// drawing
//

// Axis aligned rectangle
Rectangle :: struct {
    left: s32;
    // TODO: this should be bottom probably...
    top: s32;
    width: s32;
    height: s32;
}

bottom :: (rect: Rectangle) -> s32 #expand { return rect.top - rect.height; }
right  :: (rect: Rectangle) -> s32 #expand { return rect.left + rect.width; }

draw_axis_aligned_rectangle :: (p0: Vector2, p1: Vector2, color: Vector4) {
    Simp.immediate_quad(p0, .{ p0.x, p1.y }, p1, .{ p1.x, p0.y }, color, color, color, color);
}

draw_axis_aligned_rectangle :: (x: float, y: float, width: float, height: float, color: Vector4) {
    Simp.immediate_quad(.{ x        , y          },
                        .{ x        , y + height },
                        .{ x + width, y + height },
                        .{ x + width, y          },
                        color, color, color, color);
}

draw_axis_aligned_rectangle :: (rect: Rectangle, color: Vector4) {
    Simp.immediate_quad(.{ xx  rect.left              , xx (rect.top - rect.height) },
                        .{ xx  rect.left              , xx  rect.top                },
                        .{ xx (rect.left + rect.width), xx  rect.top                },
                        .{ xx (rect.left + rect.width), xx (rect.top - rect.height) },
                        color, color, color, color);
}

draw_hollow_axis_aligned_rectangle :: (x: float, y: float, width: float, height: float, border: float, color: Vector4) {
    draw_axis_aligned_rectangle(x, y, border, height, color);
    draw_axis_aligned_rectangle(x + border, y, width - 2 * border, border, color);
    draw_axis_aligned_rectangle(x + width - border, y, border, height, color);
    draw_axis_aligned_rectangle(x + border, y + height - border, width - 2 * border, border, color);
}

draw_fat_line :: (start: Vector2, end: Vector2, width: float32, color: Vector4) {
    direction := normalize(end - start);

    corner := Vector2.{ -(width / 2) * direction.y, (width / 2) * direction.x };

    top_l := end   - corner;
    top_r := end   + corner;
    bot_l := start - corner;
    bot_r := start + corner;

    Simp.immediate_quad(
        top_l, top_r, bot_r, bot_l,
        color, color, color, color,
    );
}

//
// math
//

axis_aligned_rectangle_contains :: inline (rect: Rectangle, point: Vector2) -> bool {
    return axis_aligned_rectangle_contains(xx rect.left, xx (rect.top - rect.height),
                                           xx rect.width, xx rect.height, point);
}

axis_aligned_rectangle_contains :: (left: float, bottom: float, width: float, height: float, point: Vector2) -> bool {
    if left > point.x            return false;
    if left + width < point.x    return false;
    if bottom > point.y          return false;
    if bottom + height < point.y return false;
    return true;
}

//
// input
//

is_click :: (code: Input.Key_Code) -> bool #expand {
    return xx (Input.input_button_states[code] & .START);
}

key_is_down :: (code: Input.Key_Code) -> bool #expand {
    return xx (Input.input_button_states[code] & .DOWN);
}

key_is_down :: ($char: string) -> bool #expand {
    #assert char.count == 1;
    return xx (Input.input_button_states[char[0]] & .DOWN);
}

//
// logging
//

my_logger :: (message: string, data: *void, info: Log_Info) {
    builder: String_Builder;
    builder.allocator = temp;
    print_time_for_log(*builder, to_calendar(current_time_consensus(), .LOCAL));
    print(*builder, ": ");
    if #compile_time print(*builder, "#compile_time ");

    filename := path_filename(info.location.fully_pathed_filename);
    print(*builder, "[%:%] %\n", filename, info.location.line_number, message);
    write_builder(*builder);
}

print_time_for_log :: (builder: *String_Builder, date_time: Calendar_Time) {
    using date_time;
    print(builder, "%:%:%.%", FormatInt.{value = hour,        minimum_digits = 2},
                              FormatInt.{value = minute,      minimum_digits = 2},
                              FormatInt.{value = second,      minimum_digits = 2},
                              FormatInt.{value = millisecond, minimum_digits = 3});
}

print_date_time_for_log :: (builder: *String_Builder, date_time: Calendar_Time) {
    using date_time;
    print(builder, "%-%-% %:%:%.%", year,
                                    FormatInt.{value = month_starting_at_0 + 1,        minimum_digits = 2},
                                    FormatInt.{value = day_of_month_starting_at_0 + 1, minimum_digits = 2},
                                    FormatInt.{value = hour,                           minimum_digits = 2},
                                    FormatInt.{value = minute,                         minimum_digits = 2},
                                    FormatInt.{value = second,                         minimum_digits = 2},
                                    FormatInt.{value = millisecond,                    minimum_digits = 3});
}

//
// another attempt at struct printer
//

my_struct_printer :: (builder: *String_Builder, any: Any, struct_printer_data: *void) -> bool {
    printer := get_constant_member_printer(any.type);
    if printer != null {
        return printer(builder, any, struct_printer_data);
    }

    if any.type == type_info(Source_Code_Location) {
        print_source_code_location(builder, xx any.value_pointer);
        return true;
    }

    return false;
}

Struct_Printer_Type :: #type (*String_Builder, Any, *void) -> bool;

get_constant_member_printer :: (base_type: *Type_Info) -> Struct_Printer_Type {
    printer_info :: type_info(Struct_Printer_Type);
    result: Struct_Printer_Type = null;

    if base_type.type != .STRUCT return null;
    type := cast(*Type_Info_Struct) base_type;
    for type.members {
        if !(it.flags & .CONSTANT) continue;
        if it.name != "printer" continue;
        if it.type != printer_info continue;

        pointer := type.constant_storage.data + it.offset_into_constant_storage;
        result = cast(*Struct_Printer_Type, pointer).*;
        return result;
    }

    return null;
}

print_source_code_location :: (builder: *String_Builder, location: *Source_Code_Location) {
    filename := path_filename(location.fully_pathed_filename);
    print(builder, "%:%", filename, location.line_number);
}

//
// miscellaneous
//

hex_color :: ($hex: string, $loc := #caller_location) -> Vector4 #expand {
    return #run -> Vector4 {
        result, ok := parse_hex_color(hex);
        assert(ok, "'%' is not a hex color", hex, loc=loc);
        context.logger = my_logger;
        log("hex_color(\"%\") = %", hex, result, loc=loc);
        return result;
    };
}

parse_hex_color :: (hex: string) -> Vector4, bool {
    if hex.count != 6 return .{}, false;

    ok := false;

    rh:, ok = hex_digit(hex[0]); if !ok return .{}, false;
    rl:, ok = hex_digit(hex[1]); if !ok return .{}, false;

    gh:, ok = hex_digit(hex[2]); if !ok return .{}, false;
    gl:, ok = hex_digit(hex[3]); if !ok return .{}, false;

    bh:, ok = hex_digit(hex[4]); if !ok return .{}, false;
    bl:, ok = hex_digit(hex[5]); if !ok return .{}, false;

    result := Vector4.{
        (rh << 4 + rl) / 255.0,
        (gh << 4 + gl) / 255.0,
        (bh << 4 + bl) / 255.0,
        1,
    };
    return result, true;
}

is_hex_digit :: inline (c: u8) -> bool {
    return c >= #char "0" && c <= #char "9"
        || c >= #char "a" && c <= #char "f"
        || c >= #char "A" && c <= #char "F";
}

hex_digit :: inline (c: u8) -> u8, bool {
    if c >= #char "0" && c <= #char "9" {
        return c - #char "0", true;
    } else if c >= #char "a" && c <= #char "f" {
        return 10 + c - #char "a", true;
    } else if c >= #char "A" && c <= #char "F" {
        return 10 + c - #char "A", true;
    } else {
        return 0xff, false;
    }
}

advance :: (array: [] u8, bytes: s64) -> result: [] u8 {
    assert(array.count >= bytes);

    result := array;
    result.data  += bytes;
    result.count -= bytes;

    return result;
}

as_bytes :: (data: *$T, count: s64) -> [] u8 {
    result: [] u8 = ---;
    result.data = xx data;
    result.count = size_of(T) * count;
    return result;
}

fmt :: (v: float64, trailing_width := 1) -> FormatFloat #expand {
    return FormatFloat.{ value = v, trailing_width = trailing_width, zero_removal = .NO };
}

fmt :: (v: float, trailing_width := 1) -> FormatFloat #expand {
    return FormatFloat.{ value = v, trailing_width = trailing_width, zero_removal = .NO };
}

profile_t0: float64 = 0.0;
Profile :: (format: string = "", args: ..Any, loc := #caller_location) #expand {
    t1 := seconds_since_init();
    elapsed := t1 - `profile_t0;
    if elapsed > .1 {
        msg := tprint(format, ..args);
        log("[elapsed: %]: %", elapsed, msg, loc=loc);
    }
    `profile_t0 = t1;
} @PrintLike

//
// footer
//

WANTED_MSAA :: 8;

#run {
    #import "Compiler";
    set_build_options_dc(.{ output_executable_name = EXE_NAME });
}

#import "Basic";
#import "String";
#import "Math";
#import "Window_Creation";
Input :: #import "Input";
Simp :: #import "Simp";
System :: #import "System";
#import "Hash_Table";
#import "File";
