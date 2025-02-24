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
    // test_search_for_match();
    // return;

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
    assert(debug_font == main_font.regular);

    msaa := Simp.prepare_window(window, wanted_msaa = WANTED_MSAA);
    Simp.set_render_target(window);

    redraw_reasons.allocator = temp;

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
redraw_reasons: [..] string;
request_redraw :: (reason: string, loc := #caller_location) {
    redraw_needed = true;
    if reason then array_add(*redraw_reasons, reason);
              else array_add(*redraw_reasons, tprint("at %", loc));
}

main_font := My_Dynamic_Font.{
    pixel_height = 14,
};

debug_font: *Simp.Dynamic_Font;
debug_text_color := #run hex_color("dddddd");

text_pane_rect: Rectangle;
left_column_rect: Rectangle;

scroll_rows := 0.0;
target_scroll_rows := 0.0;
scroll_rows_lerp_factor := 0.5;
scroll_rows_at_click := 0.0;

scroll_columns := 0.0;
target_scroll_columns := 0.0;
scroll_columns_lerp_factor := 0.5;

draggin_scroll_bar := false;
scroll_bar_rect: Rectangle;
scroll_bar_pad := 1;
scroll_bar_slider_color := #run hex_color("d0d0d0");
scroll_bar_anchor_min_width := 1.7;
scroll_bar_effective_slider_color := #run hex_color("b0b0b0");
scroll_bar_anchor_hover_color := #run hex_color("e0e0e0");

anchor_button_active_color  := #run hex_color("4050d0");
anchor_button_hover_color   := #run hex_color("404040");
anchor_line_highlight_color := #run hex_color("404040");
explicit_anchors: [..] Anchor;
Anchor :: struct {
    line_index: s64;
}
hovered_anchor_button_line: s64 = -1;

hovered_scroll_bar_anchor_kind: enum { EXPLICIT; SEARCH_MATCH; };
hovered_scroll_bar_anchor_index: s64 = -1;

color_red := #run hex_color("e04020");

//
// main update and draw proc
//

update_and_draw_frame :: () -> bool {
    t0 := seconds_since_init();

    array_reset_keeping_memory(*redraw_reasons);

    should_quit := false;

    Input.update_window_events();

    for Input.get_window_resizes() {
        assert(it.window == window);
        window_size.x = xx it.width;
        window_size.y = xx it.height;
        log("window_size: %", window_size);

        request_redraw("window size");
    }

    {
        x, y, ok := get_mouse_pointer_position(window, true);
        if ok {
            mouse.x = xx x;
            mouse.y = xx y;
        }
    }
    defer mouse_last_frame = mouse;

    //
    // update rectangles dependent on window size
    //

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
        left = max(left, xx (main_font.line_height * 3));
        top    = absolute_top;
        width  = xx (window_size.x - 40 - 100);
        height = xx window_size.y;
    }
    total_line_count := text_buffer_line_infos.count;
    text_pane_row_count := text_pane_rect.height / main_font.line_height;

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

    // text ui info
    {
        using text_search_ui_rect;
        left = absolute_left + 100;
        top = absolute_bottom + 60;
        width = 800;
        height = xx (main_font.line_height + text_search_ui_border_width * 4);
    }

    //
    // handle input events
    //

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
            request_redraw("mouse click");
            mouse_at_click = mouse;

            // if text_search_ui_active && !axis_aligned_rectangle_contains(text_search_ui_rect, mouse) {
            //     text_search_ui_active = false;
            // }
        }

        // modules/Input doesn't set it.ctrl_pressed for MOUSE_WHEEL :(
        else if it.type == .MOUSE_WHEEL && modifiers == .CTRL && !draggin_scroll_bar {
            ofs := it.wheel_delta / it.typical_wheel_delta;

            main_font.pixel_height += ofs;
            main_font.pixel_height = max(main_font.pixel_height, 1);
            reload_main_font();
            request_redraw(tprint("scroll at %", #line));
        }

        // modules/Input doesn't set it.ctrl_pressed for MOUSE_WHEEL :(
        else if it.type == .MOUSE_WHEEL && modifiers == .SHIFT && !draggin_scroll_bar {
            ofs := it.wheel_delta / cast(float) it.typical_wheel_delta;

            target_scroll_columns += -ofs * 8;
            target_scroll_columns = max(target_scroll_columns, 0);
            request_redraw(tprint("scroll at %", #line));
        }

        else if it.type == .MOUSE_WHEEL && !modifiers && !draggin_scroll_bar {
            target_scroll_rows += -3 * it.wheel_delta / cast(float) it.typical_wheel_delta;
            target_scroll_rows = clamp(target_scroll_rows, -text_pane_row_count / 2.0, total_line_count - text_pane_row_count / 2.0);
            request_redraw(tprint("scroll at %", #line));
        }

        else if it.key_code == xx #char "F" && it.ctrl_pressed && !text_search_ui_open {
            open_text_search_ui();
            // text_search_ui_active = true;
            request_redraw("open search ui");
        }

        else if it.key_pressed && it.key_code == .PAGE_UP {
            target_scroll_rows += -text_pane_row_count;
            target_scroll_rows = clamp(target_scroll_rows, -text_pane_row_count / 2.0, total_line_count - text_pane_row_count / 2.0);
        } else if it.key_pressed && it.key_code == .PAGE_DOWN {
            target_scroll_rows += text_pane_row_count;
            target_scroll_rows = clamp(target_scroll_rows, -text_pane_row_count / 2.0, total_line_count - text_pane_row_count / 2.0);
        } else if it.key_pressed && it.key_code == .ARROW_UP {
            target_scroll_rows += -(ifx it.shift_pressed then 10 else 1);
            target_scroll_rows = clamp(target_scroll_rows, -text_pane_row_count / 2.0, total_line_count - text_pane_row_count / 2.0);
        } else if it.key_pressed && it.key_code == .ARROW_DOWN {
            target_scroll_rows += (ifx it.shift_pressed then 10 else 1);
            target_scroll_rows = clamp(target_scroll_rows, -text_pane_row_count / 2.0, total_line_count - text_pane_row_count / 2.0);
        } else if it.key_pressed && it.key_code == .ARROW_LEFT {
            target_scroll_columns += -(ifx it.shift_pressed then 10 else 1);
            target_scroll_columns = max(target_scroll_columns, 0);
        } else if it.key_pressed && it.key_code == .ARROW_RIGHT {
            target_scroll_columns += (ifx it.shift_pressed then 10 else 1);
            target_scroll_columns = max(target_scroll_columns, 0);
        } else if it.key_pressed && it.key_code == .HOME {
            if it.ctrl_pressed {
                target_scroll_rows = 0;
            } else {
                target_scroll_columns = 0;
            }
        } else if it.key_pressed && it.key_code == .END && it.ctrl_pressed {
            target_scroll_rows = total_line_count - text_pane_row_count / 2.0;
        }


        else if text_search_ui_open {
            text_search_ui_handle_input_event(it);
        }
    }

    // update vertical scroll
    scroll_rows = lerp(scroll_rows, target_scroll_rows, scroll_rows_lerp_factor);
    if abs(scroll_rows - target_scroll_rows) < 0.001 then scroll_rows = target_scroll_rows;

    // update horizontal scroll
    scroll_columns = lerp(scroll_columns, target_scroll_columns, scroll_columns_lerp_factor);
    if abs(scroll_columns - target_scroll_columns) < 0.001 then scroll_columns = target_scroll_columns;

    //
    // drag scroll bar
    //
    if draggin_scroll_bar {
        mouse_moved := mouse.y - mouse_at_click.y;
        scroll_rows = scroll_rows_at_click - xx (mouse_moved * lines_per_scroll_bar_pixel);
        scroll_rows = clamp(scroll_rows, 0, total_line_count - text_pane_row_count / 2.0);
        target_scroll_rows = scroll_rows;

        if !key_is_down(.MOUSE_BUTTON_LEFT) draggin_scroll_bar = false;

        if mouse != mouse_last_frame {
            request_redraw(tprint("scroll at %", #line));
        }
    }

    //
    // update anchor buttons
    //
    {
        if !draggin_scroll_bar && axis_aligned_rectangle_contains(left_column_rect, mouse) {
            hover_line_index := screen_position_to_line_index(left_column_rect, mouse.y);
            if hover_line_index >= 0 {
                if hover_line_index != hovered_anchor_button_line {
                    hovered_anchor_button_line = hover_line_index;
                    request_redraw(tprint("anchor buttons at %", #line));
                }

                if is_click(.MOUSE_BUTTON_LEFT) {
                    found := false;
                    for explicit_anchors {
                        if it.line_index != hover_line_index continue;
                        remove it;
                        found = true;
                        break;
                    }

                    if !found {
                        array_add(*explicit_anchors, .{ hover_line_index });
                    }
                }
            } else if hovered_anchor_button_line != -1 {
                hovered_anchor_button_line = -1;
                request_redraw(tprint("anchor buttons at %", #line));
            }
        }

        if hovered_anchor_button_line != -1 && !axis_aligned_rectangle_contains(left_column_rect, mouse) {
            hovered_anchor_button_line = -1;
            request_redraw(tprint("anchor buttons at %", #line));
        }
    }

    //
    // update scroll bar anchors
    //
    if !draggin_scroll_bar {
        anchor_kind := hovered_scroll_bar_anchor_kind;
        // I'm not actually sure this is needed...
        mouse_in_rect := mouse - .{xx scroll_bar_rect.left, xx bottom(scroll_bar_rect)};
        anchor_index := do_scroll_bar_anchors(scroll_bar_rect, explicit_anchors, anchor_button_active_color, .GET_HOVER, mouse_in_rect, t=15);
        if anchor_index != -1 {
            anchor_kind = .EXPLICIT;
        } else {
            anchor_index = do_scroll_bar_anchors(scroll_bar_rect, search_results.matches, search_match_color, .GET_HOVER, mouse_in_rect);
            anchor_kind = .SEARCH_MATCH;
        }

        if anchor_index != -1 && is_click(.MOUSE_BUTTON_LEFT) {
            line_index: int;
            if #complete anchor_kind == {
                case .EXPLICIT;     line_index = explicit_anchors[anchor_index].line_index;
                case .SEARCH_MATCH; line_index = search_results.matches[anchor_index].line_index;
            }
            target_scroll_rows = xx (line_index - text_pane_row_count / 2);
            request_redraw(tprint("scroll bar anchors at %", #line));
        }

        if anchor_index != hovered_scroll_bar_anchor_index || anchor_kind != hovered_scroll_bar_anchor_kind {
            builder: String_Builder;
            builder.allocator = temp;
            if anchor_index != hovered_scroll_bar_anchor_index
                print(*builder, "% -> % ", hovered_scroll_bar_anchor_index, anchor_index);
            if anchor_kind != hovered_scroll_bar_anchor_kind
                print(*builder, "% -> % ", hovered_scroll_bar_anchor_kind, anchor_kind);
            request_redraw(builder_to_string(*builder));
            hovered_scroll_bar_anchor_index = anchor_index;
            hovered_scroll_bar_anchor_kind = anchor_kind;
        }
    }

    ////////////////////////////////////////////////////////////////////////////
    // @TEMPORARY!!!
    if mouse_last_frame != mouse {
        request_redraw("mouse moved");
    }
    if target_scroll_rows != scroll_rows || target_scroll_columns != scroll_columns {
        request_redraw(tprint("scroll animation %, %", target_scroll_columns - scroll_columns, target_scroll_rows - scroll_rows));
    }

    if !Input.input_application_has_focus return should_quit;
    if !redraw_needed return should_quit;
    // One last redraw to update the redraw reason
    redraw_needed = (redraw_reasons.count != 0);

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
        draw_the_text_pane(text_pane_rect);
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
            h := main_font.line_height - 2 * pad;
            w := h;
            x := rect.left + rect.width - w - pad + x_tweak;

            row_index := hovered_anchor_button_line - scroll_rows;
            y_line := rect.top - (row_index + 1) * main_font.line_height + y_tweak;
            y := y_line + pad;

            // draw_axis_aligned_rectangle(xx (rect.left + rect.width - main_font.line_height),
            //                             xx y_line,
            //                             xx main_font.line_height, xx main_font.line_height, hex_color("000000"));
            draw_hollow_axis_aligned_rectangle(xx x, xx y, xx w, xx h, border = 2, color);
        }

        // TODO handle search matches similarly

        // active anchor buttons
        {
            color := anchor_button_active_color;
            pad := 4;
            h := main_font.line_height - 2 * pad;
            w := h;
            x := rect.left + rect.width - w - pad + x_tweak;
            for explicit_anchors {
                row_index := it.line_index - scroll_rows;
                // -1 because want to draw half the button at the top of the screen (bad wording)
                if row_index < -1 continue;
                if row_index > xx (rect.height * main_font.line_height) continue;

                y_line := rect.top - (row_index + 1) * main_font.line_height + y_tweak;
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

        //
        // calculate the tweak that makes it so the oversized visual slider
        // doesn't overflow at the bottom of the screen
        //
        assert(scroll_bar_slider_visible_height >= scroll_bar_slider_effective_height);
        h_diff := scroll_bar_slider_visible_height - scroll_bar_slider_effective_height;
        t := scroll_rows / cast(float) total_line_count;
        y_tweak := h_diff * t;

        x := rect.left + scroll_bar_pad;

        scroll_y := scroll_rows / lines_per_scroll_bar_pixel;
        y := rect.top - scroll_y - h + y_tweak;

        // update scroll bar slider
        color := scroll_bar_slider_color;
        if is_click(.MOUSE_BUTTON_LEFT) && axis_aligned_rectangle_contains(xx x, xx y, xx w, xx h, mouse) {
            draggin_scroll_bar = true;
            scroll_rows_at_click = scroll_rows;
            request_redraw(tprint("scroll bar at %", #line));
        }

        // draw visible scroll bar slider
        draw_axis_aligned_rectangle(xx x, y, xx w, h, color);

        // draw log ranges of same source
        for i: 0..log_ranges_of_source.count-2 {
            range := log_ranges_of_source[i];
            if range.source_id == SOURCE_ID_UNKNOWN continue;

            y_top := rect.top - range.start_index / cast(float) lines_per_scroll_bar_pixel;
            y_bottom := rect.top - log_ranges_of_source[i + 1].start_index / cast(float) lines_per_scroll_bar_pixel;

            color := get_log_source_color(range.source_id);
            draw_axis_aligned_rectangle(xx x, y_bottom, xx w, y_top - y_bottom, color);
        }

        // draw visible scroll bar slider border
        {
            slider_oversize := 2;
            X := x - slider_oversize;
            Y := y - slider_oversize;
            W := w + slider_oversize;
            H := h + 2 * slider_oversize;
            draw_hollow_axis_aligned_rectangle(xx X, xx Y, xx W, xx H, border = 2, color);
        }

        // draw effective scroll bar slider
        if scroll_bar_slider_visible_height != scroll_bar_slider_effective_height {
            color := scroll_bar_effective_slider_color;
            x_pad := 2;
            h := scroll_bar_slider_effective_height;
            y := rect.top - scroll_y - h;
            draw_axis_aligned_rectangle(xx (x + x_pad), y, xx (w - 2 * x_pad), xx h, color);
        }

        // draw scroll bar anchors
        {
            mouse_in_rect := mouse - .{xx scroll_bar_rect.left, xx bottom(scroll_bar_rect)};
            search_match_index := do_scroll_bar_anchors(scroll_bar_rect, search_results.matches, search_match_color, .DRAW, mouse_in_rect);
            // explicit anchors have higher priority
            explicit_anchor_index := do_scroll_bar_anchors(scroll_bar_rect, explicit_anchors, anchor_button_active_color, .DRAW, mouse_in_rect, t=15);
            if explicit_anchor_index != -1 {
                line_index := explicit_anchors[explicit_anchor_index].line_index;
                draw_single_scroll_bar_anchor(scroll_bar_rect, line_index, anchor_button_active_color, hover=true, t=15);
            } else if search_match_index != -1 {
                match := search_results.matches[search_match_index];
                color := get_log_source_color(match.source_id);
                draw_single_scroll_bar_anchor(scroll_bar_rect, match.line_index, color, hover=true);
            }
        }

        if text_search_ui_open {
            draw_text_search_ui(text_search_ui_rect, main_font);
        }
    }

    // debuggin pane
    {
        rect := window_rect;
        font := debug_font;
        x := right(window_rect) - 300;
        y := window_rect.top - 4;

        builder: String_Builder; builder.allocator = temp;
        elapsed := seconds_since_init() - t0;
        print(*builder, "% %\n", frame_counter, fmt(elapsed, 6));
        print(*builder, "scroll: %, %\n", fmt(scroll_columns, 1), fmt(scroll_rows, 1));
        print(*builder, "num sources: %\n", text_buffer_all_log_sources.count);
        // print(*builder, "num ranges: %\n", log_ranges_of_source.count);
        if text_search_ui_open print(*builder, "cursor: %\n", text_input_cursor);
        if text_search_ui_open print(*builder, "search matches: %\n", search_results.matches.count);
        if hovered_scroll_bar_anchor_index != -1 then print(*builder, "% %\n", hovered_scroll_bar_anchor_kind, hovered_scroll_bar_anchor_index);
        // if text_search_ui_open print(*builder, "case-insensitive: %\n", search_results.case_insensitive);
        for redraw_reasons print(*builder, "%\n", it);
        // print(*builder, "mouse_from_top: %\n", rect.top - mouse.y);
        // print(*builder, "main_font_line_height: %\n", main_font.line_height);

        pane_text := builder_to_string(*builder,, temp);
        draw_simple_text_pane(rect, font, x, y, pane_text, hex_color("ffffff"), hex_color("181818"));
    }

    // // @TEMPORARY
    // {
    //     p0 := Vector2.{left(window_rect) + width(window_rect) * .27, top(window_rect) - height(window_rect) * .2};
    //     p1 := Vector2.{left(window_rect) + width(window_rect) * .27, bottom(window_rect) + height(window_rect) * .2};
    //     p2 := Vector2.{right(window_rect) - width(window_rect) * .27, bottom(window_rect) + height(window_rect) * .5};
    //     color := hex_color("808080");
    //     if triangle_contains(p0, p1, p2, mouse) {
    //         color = color_red;
    //     }
    //     draw_triangle(p0, p1, p2, color);
    // }

    Simp.swap_buffers(window);
    Profile();
    frame_counter += 1;

    return should_quit;
}

//
// scroll bar stuff
//

do_scroll_bar_anchors :: (parent_rect: Rectangle, anchors: [] $T, color: Vector4, $mode: enum { DRAW; GET_HOVER; }, target_in_rect: Vector2, $$t := 10.0) -> (index: s64) {
    target := target_in_rect;
    hover_color := scroll_bar_anchor_hover_color;
    color_ := color;

    hover_indexes: [..] int;
    hover_indexes.allocator = temp;
    array_reserve(*hover_indexes, 16);

    x, effective_h, w, h := scroll_bar_anchor_parameters(parent_rect, text_buffer_line_infos.count);
    slack :: 1.2;
    for anchors {
        y := parent_rect.top - (it.line_index + 1) * effective_h;

        hover := (target.x >= -t && target.x <= xx parent_rect.width && target.y >= y - slack && target.y <= y + h + slack);

        #if #complete mode == {
        case .DRAW;
            #if T == Search_Match_Info then color_ = get_log_source_color(it.source_id);
            inline draw_scroll_bar_anchor(x, y, w, h, t, color_, false);
            if hover then array_add(*hover_indexes, it_index);

        case .GET_HOVER;
            if hover {
                array_add(*hover_indexes, it_index);
            } else if hover_indexes {
                // not hovering anymore, but had some hovers, which means we're
                // past the hovered ones. I speak not good
                return hover_indexes[hover_indexes.count / 2];
            }
        }
    }

    if !hover_indexes return -1;
    // return the middle one
    return hover_indexes[hover_indexes.count / 2];
}

draw_single_scroll_bar_anchor :: (parent_rect: Rectangle, line_index: int, color: Vector4, $$t := 10.0, hover: bool) {
    x, effective_h, w, h := scroll_bar_anchor_parameters(parent_rect, text_buffer_line_infos.count);
    y := parent_rect.top - (line_index + 1) * effective_h;

    inline draw_scroll_bar_anchor(x, y, w, h, t, color, hover);
}

scroll_bar_anchor_parameters :: (parent_rect: Rectangle, max_count: int) -> (x: float, effective_h: float, w: float, h: float) {
    effective_h := parent_rect.height / cast(float) max_count;
    x := cast(float) parent_rect.left;
    w := cast(float) parent_rect.width;
    h := cast(float) max(scroll_bar_anchor_min_width, effective_h);

    return x, effective_h, w, h;
}

draw_scroll_bar_anchor :: (x: float, y: float, w: float, h: float, $$t: float, color: Vector4, hover: bool) {
    hover_color := scroll_bar_anchor_hover_color;

    triangle_middle_x_tweak :: 2.0;

    if hover {
        draw_axis_aligned_rectangle(x, y - 1, xx w, 1, hover_color);
        draw_axis_aligned_rectangle(x, y + h, xx w, 1, hover_color);
    }
    draw_axis_aligned_rectangle(xx x, y, xx w, h, color);
    {
        Y := y + h / 2;
        p0 := Vector2.{x - triangle_middle_x_tweak, Y};
        p1 := p0 + .{triangle_middle_x_tweak - t, -t/2};
        p2 := p0 + .{triangle_middle_x_tweak - t,  t/2};
        if hover {
            draw_triangle(p0 + .{ 2, 0 }, p1 + .{ -1.333333, -2 }, p2 + .{ -1.333333, 2 }, hover_color);
        }
        draw_triangle(p0, p1, p2, color);
    }

}


//
// text pane stuff
//

main_text_pane_text_color       := #run hex_color("e0e0e0");
main_text_pane_background_color := #run hex_color("202020");

draw_the_text_pane :: (rect: Rectangle) {
    text_color       := main_text_pane_text_color;
    background_color := main_text_pane_background_color;

    // background
    {
        draw_axis_aligned_rectangle(rect, background_color);
    }

    hover_line_index := -1;
    if axis_aligned_rectangle_contains(rect, mouse) {
        hover_line_index = screen_position_to_line_index(rect, mouse.y);
    }

    // text
    {
        tail := text_buffer_data;

        h := main_font.line_height;

        text_x_tweak := 4.0;
        pane_width_in_characters := (rect.width - text_x_tweak) / main_font.mono_width;

        x := rect.left + text_x_tweak;
        y := rect.top - h + scroll_rows * main_font.line_height;
        text_y_tweak := -(main_font.typical_descender + main_font.max_descender) / 2;

        search_matches_cursor := 0;
        line_index := 0;
        while tail {
            defer line_index += 1;
            found:, line:, tail = split_from_left(tail, #char "\n");

            defer y -= h;
            if y > xx rect.top continue;
            if y < xx (rect.top - rect.height - h) continue;

            anchored := false;
            for explicit_anchors if it.line_index == line_index { anchored = true; break; }
            if anchored {
                w := rect.width;
                h := 2;
                x := rect.left;
                y_tweak := -2;
                y_bottom := y + y_tweak;
                y_top := y + main_font.line_height + y_tweak;
                draw_axis_aligned_rectangle(xx x, xx y_bottom, xx w, 2, anchor_line_highlight_color);
                draw_axis_aligned_rectangle(xx x, xx y_top,    xx w, 2, anchor_line_highlight_color);
            }

            n_columns_to_skip := cast(int) floor(scroll_columns);
            x_tweak := (scroll_columns - n_columns_to_skip) * main_font.mono_width;

            if xx line.count > scroll_columns {
                info := *text_buffer_line_infos[line_index];
                color := text_color;
                if info.source_id != SOURCE_ID_UNKNOWN {
                    color = get_log_source_color(info.source_id);
                }

                font := main_font.regular;
                if line_index == hover_line_index {
                    font = main_font.bold;
                }

                line = advance(line, n_columns_to_skip);
                line.count = min(line.count, xx pane_width_in_characters);

                w_text := Simp.prepare_text(font, line);
                // This fails for unicode!
                // assert(w_text == main_font.mono_width * line.count);

                // if line_index % 2 == 0
                //     draw_axis_aligned_rectangle(xx x, xx y, xx rect.width, xx main_font.line_height, hex_color("005050"));

                Simp.draw_prepared_text(font, xx (x - x_tweak), xx y + text_y_tweak, color);
            }

            // handle search match
            if text_search_ui_open
                // TODO @INCOMPLETE draw all matches, not just the first ones
                draw_search_match_border(rect, main_font, text_x_tweak, y, line_index, *search_matches_cursor);

        }

    }

}

draw_search_match_border :: (parent_rect: Rectangle, font: My_Dynamic_Font, text_x_tweak: float, y: float, line_index: int, cursor: *int) {
    search_match: *Search_Match_Info = null;
    color := search_match_color;

    while cursor.* < search_results.matches.count {
        it := *search_results.matches[cursor.*];
        if it.line_index == line_index {
            search_match = it;
            break;
        } else if it.line_index > line_index {
            break;
        }
        cursor.* += 1;
    }

    if !search_match return;

    border_width := 2.0;

    // @ROBUSTNESS this y_tweak is copy-pasted from anchors code
    y_tweak := -border_width;
    y_bottom := y + y_tweak;
    h := font.line_height + border_width;
    h23 := 2 * h / 5;

    // @ROBUSTNESS this global variable `scroll_columns` access is kinda ass
    x_in_rect := font.mono_width * (search_match.offset_in_line - scroll_columns) + text_x_tweak - border_width;
    if x_in_rect > xx parent_rect.width {
        p0 := Vector2.{xx right(parent_rect), y_bottom + h/2};
        p1 := p0 + .{-h23, -h23};
        p2 := p0 + .{-h23,  h23};
        draw_fat_line(p0, p1, border_width, color);
        draw_fat_line(p0, p2, border_width, color);
        return;
    }

    // @INCOMPLETE unicode not supported
    w := search_results.search_string.count * font.mono_width + border_width * 2;
    if x_in_rect + w < 0 {
        p0 := Vector2.{xx parent_rect.left, y_bottom + h/2};
        p1 := p0 + .{h23, -h23};
        p2 := p0 + .{h23,  h23};
        draw_fat_line(p0, p1, border_width, color);
        draw_fat_line(p0, p2, border_width, color);
        return;
    }

    x := parent_rect.left + x_in_rect;
    // @INCOMPLETE currently drawing outside `parent_rect` sometimes
    draw_hollow_axis_aligned_rectangle(xx x, xx y_bottom, xx w, xx h, border = 2, color);

}

screen_position_to_line_index :: (rect: Rectangle, y: float) -> s64 {
    if y > xx rect.top return -1;
    rect_bottom := rect.top - rect.height;
    if y < xx rect_bottom return -1;

    // Am I retarded?
    y_in_rect_from_top := rect.top - y;
    row_index := floor(scroll_rows + y_in_rect_from_top / main_font.line_height);
    return xx row_index;
}

//
// text buffer stuff
//

text_buffer_data: string;
text_buffer_all_log_sources: [..] string;
text_buffer_line_infos: [..] Log_Line_Info;

Log_Line_Info :: struct {
    line_offset: s64;
    source_id: u8 = SOURCE_ID_UNKNOWN;
    source_start: u8;
    // TODO: timestamp
}

log_source_color_scheme := Vector4.[
    #run hex_color("db0011"), // red
    #run hex_color("00c52c"), // green
    #run hex_color("0069cb"), // blue
    #run hex_color("ff8080"), // coral-ish
    #run hex_color("ffdf00"), // yellow
    #run hex_color("cd00b7"), // magenta
    #run hex_color("00d8db"), // baby blue
    #run hex_color("ff6b00"), // orange
    #run hex_color("a000ff"), // purple
    #run hex_color("ffffff"), // white
    #run hex_color("973f00"), // brown
];

get_log_source_color :: (source_id: u8) -> Vector4 #expand {
    return log_source_color_scheme[source_id % log_source_color_scheme.count];
}

Log_Range :: struct {
    source_id: u8;
    start_index: int;
}
log_ranges_of_source: [..] Log_Range;

SOURCE_ID_UNKNOWN :: cast(u8) 0xff;

load_text_buffer_data :: () {
    text_buffer_data=, ok := read_entire_file(tprint("%/sample_log.txt", assets_directory));
    // text_buffer_data=, ok := read_entire_file("main.jai");
    // text_buffer_data=, ok := read_entire_file(tprint("%/test.log", assets_directory));
    assert(ok);

    array_reset_keeping_memory(*text_buffer_all_log_sources);
    array_reserve(*text_buffer_all_log_sources, SOURCE_ID_UNKNOWN);
    array_reset_keeping_memory(*text_buffer_line_infos);
    array_reset_keeping_memory(*log_ranges_of_source);

    max_line_length := 0;

    tail := text_buffer_data;
    line_index := 0;
    while tail {
        defer line_index += 1;
        found:, line:, tail = split_from_left(tail, #char "\n");
        info := array_add(*text_buffer_line_infos);
        info.line_offset = line.data - text_buffer_data.data;

        max_line_length = max(max_line_length, line.count);

        ok := inline parse_text_buffer_log_line(line, info);

        if log_ranges_of_source.count == 0 || last(log_ranges_of_source).source_id != info.source_id {
            array_add(*log_ranges_of_source, .{ info.source_id, line_index });
        }

        if !ok continue;

    }

    // Add a dummy range start at the end for convenience
    array_add(*log_ranges_of_source, .{ SOURCE_ID_UNKNOWN, line_index });

    // line_index := 0;
    // while line_index < text_buffer_line_infos.count {
    //     defer line_index += 1000;
    //     array_add(*explicit_anchors, .{ line_index });
    // }

    log("line count: %", text_buffer_line_infos.count);
    log("max line length: %", max_line_length);
}

parse_text_buffer_log_line :: (line: string, info: *Log_Line_Info) -> bool {
    cursor := 0;

    // skip whitespace
    while cursor < line.count && is_space(line[cursor]) { cursor += 1; }
    if cursor >= line.count return false;

    source_start := cursor;
    while cursor < line.count {
        c := line[cursor];
        if !(is_alpha(c) || is_digit(c) || c == #char ":" || c == #char "_") break;
        cursor += 1;
    }
    if cursor == source_start return false;

    source_count := cursor - source_start;

    // skip whitespace
    while cursor < line.count && is_space(line[cursor]) { cursor += 1; }
    if cursor >= line.count return false;
    if line[cursor] != #char "|" return false;

    source := slice(line, source_start, source_count);
    info.source_start = xx source_start;

    source_id := add_source(*text_buffer_all_log_sources, source);
    info.source_id = source_id;

    return true;
}

add_source :: (sources: *[..] string, source: string) -> u8 {
    for sources.* {
        if it == source return xx it_index;
    }

    if sources.count == SOURCE_ID_UNKNOWN return SOURCE_ID_UNKNOWN;

    array_add(sources, source);
    return xx (sources.count - 1);
}

//
// text search stuff
//

Search_Results :: struct {
    search_string_storage: [256] u8;
    search_string: string;
    case_insensitive := false;
    matches: [..] Search_Match_Info;
}

Search_Match_Info :: struct {
    line_index: s32;
    offset_in_line: s16;
    source_id: u8 = SOURCE_ID_UNKNOWN;
}

search_match_color :: #run hex_color("f5a511");

search_results: Search_Results;

update_text_buffer_search_results :: (search_string: string) {
    assert(search_string.count < search_results.search_string_storage.count, "%", search_string.count);
    memcpy(search_results.search_string_storage.data, search_string.data, search_string.count);
    search_results.search_string_storage[search_string.count] = 0;
    search_results.search_string.data = search_results.search_string_storage.data;
    search_results.search_string.count = search_string.count;

    array_reset_keeping_memory(*search_results.matches);
    search_results.case_insensitive = false;

    if !search_string return;

    search_string_lowercase := to_lower_copy(search_string,, temp);
    for search_string if is_alpha(it) { search_results.case_insensitive = true; break; }

    next_range_cursor := 0;

    for line_index: 0..text_buffer_line_infos.count - 2 {
        info := text_buffer_line_infos[line_index];
        next_info := text_buffer_line_infos[line_index + 1];
        line_length := next_info.line_offset - info.line_offset - 1; // - 1 because there's a "\n"
        line := slice(text_buffer_data, info.line_offset, line_length);

        if !line continue;

        offset := 0;
        if search_results.case_insensitive then offset = search_for_match_case_insensitive(line, search_string_lowercase);
                                           else offset = search_for_match_case_sensitive(line, search_string_lowercase);

        source_id := SOURCE_ID_UNKNOWN;
        while next_range_cursor < log_ranges_of_source.count {
            if log_ranges_of_source[next_range_cursor].start_index > line_index break;
            next_range_cursor += 1;
        }
        assert(next_range_cursor > 0);
        range_info := log_ranges_of_source[next_range_cursor - 1];
        assert(range_info.start_index <= line_index);
        source_id = range_info.source_id;

        if offset >= 0 {
            assert(offset <= S16_MAX, "%", offset);
            array_add(*search_results.matches, Search_Match_Info.{ xx line_index, xx offset, source_id });
        }
    }
    // FIXME: ignoring the last line for now, cause i'm lazy
}

search_for_match_case_sensitive :: (line: string, search_string: string, $max_offset: int = S16_MAX, $do_assert := false) -> s64 {
    first_char := search_string[0];
    i := find_index_from_left(line, first_char);

    if i < 0 || i >= max_offset return -1;

    match_start, match_length := i, 1;
    if match_length == search_string.count return match_start;

    line_length_clamped := min(line.count, max_offset + 1);

    i += 1;
    while i < line.count {
        if line[i] == search_string[match_length] {
            match_length += 1;
            if match_length == search_string.count return match_start;
            i += 1;
            continue;
        }

        match_length = 0;
        // XXX: overlapping matches are not supported!!!
        while (i < line_length_clamped) && (line[i] != search_string[match_length]) { i += 1; }
        if i >= line_length_clamped return -1;

        match_start, match_length = i, 1;
        i += 1;
    }

    return -1;
}

search_for_match_case_insensitive :: (line: string, search_string: string, $max_offset: int = S16_MAX, $do_assert := false) -> s64 {
    #if do_assert assert(is_lower(search_string));

    first_char_lower := search_string[0];
    i1 := inline find_index_from_left(line, first_char_lower);

    i2 := -1;
    if first_char_lower >= #char "a" && first_char_lower <= #char "z" {
        first_char_upper := inline to_upper(first_char_lower);
        i2 = inline find_index_from_left(line, first_char_upper);
    }

    i := 0;
    if i1 < 0 || i1 >= max_offset {
        if i2 < 0 || i2 >= max_offset return -1;   else i = i2;
    } else {
        if i2 < 0 || i2 >= max_offset then i = i1; else i = min(i1, i2);
    }

    match_start, match_length := i, 1;
    if match_length == search_string.count return match_start;

    line_length_clamped := min(line.count, max_offset + 1);

    i += 1;
    while i < line.count {
        char := line[i];
        if (inline to_lower(char)) == search_string[match_length] {
            match_length += 1;
            if match_length == search_string.count return match_start;
            i += 1;
            continue;
        }

        match_length = 0;
        // XXX: overlapping matches are not supported!!!
        while (i < line_length_clamped) && ((inline to_lower(line[i])) != search_string[match_length]) { i += 1; }
        if i >= line_length_clamped return -1;

        match_start, match_length = i, 1;
        i += 1;
    }

    return -1;
}

test_search_for_match :: () {
    line :: "aaabBbccCaAAadddAaAaAeEe";
    i: int;
    i = search_for_match_case_insensitive(line, "a",      do_assert=true); pretty_assert(i == 0);
    i = search_for_match_case_insensitive(line, "aa",     do_assert=true); pretty_assert(i == 0);
    i = search_for_match_case_insensitive(line, "aaa",    do_assert=true); pretty_assert(i == 0);
    i = search_for_match_case_insensitive(line, "aaaa",   do_assert=true); pretty_assert(i == 9);
    i = search_for_match_case_insensitive(line, "aaaaa",  do_assert=true); pretty_assert(i == 16);
    i = search_for_match_case_insensitive(line, "aaaaaa", do_assert=true); pretty_assert(i == -1);

    i = search_for_match_case_insensitive(line, "b",      do_assert=true); pretty_assert(i == 3);
    i = search_for_match_case_insensitive(line, "bb",     do_assert=true); pretty_assert(i == 3);
    i = search_for_match_case_insensitive(line, "bbb",    do_assert=true); pretty_assert(i == 3);

    i = search_for_match_case_insensitive(line, "c",      do_assert=true); pretty_assert(i == 6);
    i = search_for_match_case_insensitive(line, "cc",     do_assert=true); pretty_assert(i == 6);
    i = search_for_match_case_insensitive(line, "ccc",    do_assert=true); pretty_assert(i == 6);

    i = search_for_match_case_insensitive(line, "d",      do_assert=true); pretty_assert(i == 13);
    i = search_for_match_case_insensitive(line, "dd",     do_assert=true); pretty_assert(i == 13);
    i = search_for_match_case_insensitive(line, "ddd",    do_assert=true); pretty_assert(i == 13);

    i = search_for_match_case_insensitive(line, "e",      do_assert=true); pretty_assert(i == 21);
    i = search_for_match_case_insensitive(line, "ee",     do_assert=true); pretty_assert(i == 21);
    i = search_for_match_case_insensitive(line, "eee",    do_assert=true); pretty_assert(i == 21);

    i = search_for_match_case_sensitive(line, "a",      do_assert=true); pretty_assert(i == 0);
    i = search_for_match_case_sensitive(line, "A",      do_assert=true); pretty_assert(i == 10);
    i = search_for_match_case_sensitive(line, "aa",     do_assert=true); pretty_assert(i == 0);
    i = search_for_match_case_sensitive(line, "aA",     do_assert=true); pretty_assert(i == 9);
    i = search_for_match_case_sensitive(line, "Aa",     do_assert=true); pretty_assert(i == 11);
    i = search_for_match_case_sensitive(line, "AA",     do_assert=true); pretty_assert(i == 10);
    i = search_for_match_case_sensitive(line, "aaa",    do_assert=true); pretty_assert(i == 0);
    i = search_for_match_case_sensitive(line, "aaA",    do_assert=true); pretty_assert(i == -1);
    i = search_for_match_case_sensitive(line, "aAa",    do_assert=true); pretty_assert(i == 17);
    i = search_for_match_case_sensitive(line, "aAA",    do_assert=true); pretty_assert(i == 9);
    i = search_for_match_case_sensitive(line, "Aaa",    do_assert=true); pretty_assert(i == -1);
    i = search_for_match_case_sensitive(line, "AaA",    do_assert=true); pretty_assert(i == 16);
    i = search_for_match_case_sensitive(line, "AAa",    do_assert=true); pretty_assert(i == 10);
    i = search_for_match_case_sensitive(line, "AAA",    do_assert=true); pretty_assert(i == -1);
    i = search_for_match_case_sensitive(line, "aaaa",   do_assert=true); pretty_assert(i == -1);
    i = search_for_match_case_sensitive(line, "aAAa",   do_assert=true); pretty_assert(i == 9);
    i = search_for_match_case_sensitive(line, "AaAa",   do_assert=true); pretty_assert(i == 16);
    i = search_for_match_case_sensitive(line, "aAaA",   do_assert=true); pretty_assert(i == 17);
    i = search_for_match_case_sensitive(line, "AaaA",   do_assert=true); pretty_assert(i == -1);
    i = search_for_match_case_sensitive(line, "aaaaa",  do_assert=true); pretty_assert(i == -1);
    i = search_for_match_case_sensitive(line, "aaaaaa", do_assert=true); pretty_assert(i == -1);
}

a_to_A :: #char "A" - #char "a";
A_to_a :: #char "a" - #char "A";

other_case :: inline (char: u8) -> (char: u8, ok: bool) {
    if      (char >= #char "a") && (char <= #char "z") return char - A_to_a, true;
    else if (char >= #char "A") && (char <= #char "Z") return char + A_to_a, true;
    else return char, false;
}

//
// font stuff
//

My_Dynamic_Font :: struct {
    using regular: *Simp.Dynamic_Font;
    bold: *Simp.Dynamic_Font;
    pixel_height: int;
    mono_width: int;
    line_height: int;
}

reload_main_font :: () {
    load_font("Codetta-Regular.ttf", "Codetta-Bold.ttf", *main_font);
}

load_font :: (regular_name: string, bold_name: string, font: *My_Dynamic_Font) {
    assert(font.pixel_height >= 0);

    log("loading '%' at size %", regular_name, font.pixel_height);
    font.regular = Simp.get_font_at_size(assets_directory, regular_name, font.pixel_height);

    log("loading '%' at size %", bold_name, font.pixel_height);
    font.bold = Simp.get_font_at_size(assets_directory, bold_name, font.pixel_height);

    font.line_height = xx (font.character_height - font.typical_descender);
    text_width := Simp.prepare_text(font.regular, "abc");
    font.mono_width = text_width / 3;
}

//
// text search ui
//

text_search_ui_open := false;
text_search_ui_active := false;
text_search_builder: String_Builder;
text_search_string: string;
text_search_ui_rect: Rectangle;

text_search_ui_background_color := #run hex_color("181818");
text_search_ui_border_color := #run hex_color("303030");
text_search_ui_cursor_color := #run hex_color("ffffff");
text_search_ui_text_color := #run hex_color("ffffff");
text_search_ui_border_width := 3.0;

text_input_cursor: s64;
text_input_buffer: [..] u8;

open_text_search_ui :: () {
    text_search_ui_open = true;
}

close_text_search_ui :: () {
    text_search_ui_open = false;
}

text_search_ui_handle_input_event :: (event: Input.Event) {
    if !event.key_pressed return;

    if event.key_code >= #char " " && event.key_code <= #char "~" {
        if event.ctrl_pressed return;
        if event.alt_pressed return;

        char := cast(u8) event.key_code;
        if event.shift_pressed {
            if char == {
                case #char "`";  char = #char "~";
                case #char "1";  char = #char "!";
                case #char "2";  char = #char "@";
                case #char "3";  char = #char "#";
                case #char "4";  char = #char "$";
                case #char "5";  char = #char "%";
                case #char "6";  char = #char "^";
                case #char "7";  char = #char "&";
                case #char "8";  char = #char "*";
                case #char "9";  char = #char "(";
                case #char "0";  char = #char ")";
                case #char "-";  char = #char "_";
                case #char "[";  char = #char "{";
                case #char "]";  char = #char "}";
                case #char "\\"; char = #char "|";
                case #char ";";  char = #char ":";
                case #char "'";  char = #char "\"";
                case #char ",";  char = #char "<";
                case #char ".";  char = #char ">";
                case #char "/";  char = #char "?";
            }
        } else {
            if char >= #char "A" && char <= #char "Z" {
                char += #char "a" - #char "A";
            } else if char == {
                // WTF is this???
                case #char "+"; char = #char "=";
            }
        }

        array_insert_at(*text_input_buffer, char, text_input_cursor);
        text_input_cursor += 1;

        update_text_buffer_search_results(xx text_input_buffer);

        request_redraw(tprint("text search at %", #line));
    } else if event.key_code == {
        case .ESCAPE;
            close_text_search_ui();
            request_redraw(tprint("text search at %", #line));

        case .BACKSPACE;
            if text_input_cursor > 0 {
                array_ordered_remove_range(*text_input_buffer, text_input_cursor - 1, text_input_cursor);
                text_input_cursor -= 1;
                request_redraw(tprint("text search at %", #line));

                update_text_buffer_search_results(xx text_input_buffer);
            }

        case .DELETE;
            if text_input_buffer.count > 0 && text_input_cursor < text_input_buffer.count {
                array_ordered_remove_range(*text_input_buffer, text_input_cursor, text_input_cursor + 1);
                request_redraw(tprint("text search at %", #line));

                update_text_buffer_search_results(xx text_input_buffer);
            }

        case .ARROW_LEFT;
            if text_input_cursor > 0 then text_input_cursor -= 1;
            request_redraw(tprint("text search at %", #line));

        case .ARROW_RIGHT;
            if text_input_cursor < text_input_buffer.count then text_input_cursor += 1;
            request_redraw(tprint("text search at %", #line));

        case .ARROW_UP; // TODO: history
        case .ARROW_DOWN; // TODO: history

        case .HOME;
            text_input_cursor = 0;
            request_redraw(tprint("text search at %", #line));

        case .END;
            text_input_cursor = text_input_buffer.count;
            request_redraw(tprint("text search at %", #line));

        case .ENTER;
            forwards := !event.shift_pressed;
            // TODO: @ROBUSTNESS this approach sucks, it's better to keep track
            // of currently selected match and do everything based on it, could
            // even highlight it some how
            line_index := cast(int) floor(target_scroll_rows);

            matched_line_index := -1;
            if forwards {
                for search_results.matches {
                    if it.line_index > line_index {
                        matched_line_index = it.line_index;
                        break;
                    }
                }
            } else {
                for < search_results.matches {
                    if it.line_index < line_index {
                        matched_line_index = it.line_index;
                        break;
                    }
                }
            }

            if matched_line_index >= 0 {
                target_scroll_rows = xx matched_line_index;
            }
    }
}

draw_text_search_ui :: (rect: Rectangle, font: My_Dynamic_Font) {
    draw_axis_aligned_rectangle(rect, text_search_ui_background_color);
    draw_hollow_axis_aligned_rectangle(xx rect.left, xx bottom(rect), xx rect.width, xx rect.height,
                                       border = text_search_ui_border_width, text_search_ui_border_color);

    border_width := text_search_ui_border_width;
    text_x_tweak := border_width * 2 + 2;
    text_y_tweak := border_width * 2 + 2;
    text_x := rect.left + text_x_tweak;
    text_y := bottom(rect) + text_y_tweak;

    Simp.draw_text(font.regular, xx text_x, xx text_y, xx text_input_buffer, text_search_ui_text_color);

    // TODO: scrolling
    {
        x := text_x + font.mono_width * text_input_cursor;
        cursor_y_tweak := -2.0;
        y := text_y + cursor_y_tweak;
        w := 2;
        h := font.line_height;

        draw_axis_aligned_rectangle(xx x, xx y, xx w, xx h, text_search_ui_cursor_color);
    }
}

//
// ui primitives
//

draw_simple_text_pane :: (parent_rect: Rectangle, font: *Simp.Dynamic_Font, left: s64, top: s64, text: string, text_color: Vector4, background_color: Vector4) {
    if !text return;

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

    x := parent_rect.left + left;
    y := bottom(parent_rect) + top;

    // draw background rect
    {
        X := x - x_pad;
        H := h * line_count;
        Y := y - H + 1;
        W := text_w_max + x_pad * 2;
        draw_axis_aligned_rectangle(xx X, xx Y, xx W, xx H, background_color);
    }

    // draw the text
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

top    :: (rect: Rectangle) -> s32 #expand { return rect.top;               }
bottom :: (rect: Rectangle) -> s32 #expand { return rect.top - rect.height; }
left   :: (rect: Rectangle) -> s32 #expand { return rect.left;              }
right  :: (rect: Rectangle) -> s32 #expand { return rect.left + rect.width; }
width  :: (rect: Rectangle) -> s32 #expand { return rect.width;             }
height :: (rect: Rectangle) -> s32 #expand { return rect.height;            }

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

draw_triangle :: inline (p0: Vector2, p1: Vector2, p2: Vector2, color: Vector4) {
    Simp.immediate_triangle(.{ p0.x, p0.y, 1 }, .{ p1.x, p1.y, 1 }, .{ p2.x, p2.y, 1 }, color, color, color);
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

// source: https://stackoverflow.com/a/2049593
triangle_contains :: (p0: Vector2, p1: Vector2, p2: Vector2, target: Vector2) -> bool {
    sign :: (p0: Vector2, p1: Vector2, p2: Vector2) -> float #expand {
        return (p0.x - p2.x) * (p1.y - p2.y) - (p1.x - p2.x) * (p0.y - p2.y);
    }

    d0 := sign(target, p0, p1);
    d1 := sign(target, p1, p2);
    d2 := sign(target, p2, p0);

    has_neg := (d0 < 0) || (d1 < 0) || (d2 < 0);
    has_pos := (d0 > 0) || (d1 > 0) || (d2 > 0);

    return !(has_neg && has_pos);
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

array_ordered_remove_range :: inline (array_pointer: *[] $T, start: s64, end: s64) {
    assert(0 <= start, "start: %", start);
    assert(start < array_pointer.count, "start: %, array_poniter.count: %", start, array_pointer.count);
    assert(start <= end, "start: %, end: %", start, end);
    assert(end <= array_pointer.count, "end: %, array_poniter.count: %", end, array_pointer.count);

    if start == end return;

    array := <<array_pointer;
    count := end - start;

    for i : start..array.count-count-1
        array[i] = array[i+count];

    array_pointer.count -= count;
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

last :: (array: [] $T) -> T #expand {
    return array[array.count - 1];
}

is_lower :: (s: string) -> bool {
    for s if (it < #char "a") || (it > #char "z") return false;
    return true;
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
// pretty assert
//

// Constant structs don't work with compile time constructs yet, so we return
// all fields directly
get_expr_info :: (code: Code) -> kind: Code_Node.Kind, op_type: s32, full_expr: string, proc_expr: string, lhs: Code, rhs: Code {
    #import "Program_Print";

    root := compiler_get_nodes(code);

    builder: String_Builder;
    print_expression(*builder, root);
    full_expr := builder_to_string(*builder);

    if root.kind == {
        case .BINARY_OPERATOR;
            binop := cast(*Code_Binary_Operator) root;
            op_type := binop.operator_type;
            lhs := compiler_get_code(binop.left, code);
            rhs := compiler_get_code(binop.right, code);
            return xx root.kind, op_type, full_expr, "", lhs, rhs;

        case .PROCEDURE_CALL;
            proccall := cast(*Code_Procedure_Call) root;
            if proccall.arguments_sorted.count != 2 {
                dummy : Code = #code null;
                return xx root.kind, -1, full_expr, "", dummy, dummy;
            }

            builder: String_Builder;
            print_expression(*builder, proccall.procedure_expression);
            proc_expr := builder_to_string(*builder);

            lhs := compiler_get_code(proccall.arguments_sorted[0], code);
            rhs := compiler_get_code(proccall.arguments_sorted[1], code);
            return xx root.kind, -1, full_expr, proc_expr, lhs, rhs;

        case;

    }

    dummy : Code = #code null;
    return xx root.kind, -1, full_expr, "", dummy, dummy;
}

pretty_assert :: (code: Code, loc := #caller_location) #expand {
    if #insert code return;

    if context.handling_assertion_failure  return;  // Avoid infinite loops.
    context.handling_assertion_failure = true;

    kind, op_type, full_expr, proc_expr, lhs, rhs :: #run get_expr_info(code);

    message := "";

    #if kind == .BINARY_OPERATOR {
        builder : String_Builder;
        builder.allocator = temporary_allocator;

        print_to_builder(*builder, "(%) = (% ", full_expr, #insert lhs);

        if op_type < 128 {
            append(*builder, cast(u8) op_type);
        } else {
            append(*builder, operator_to_string(xx op_type));
        }

        print_to_builder(*builder, " %) = false", #insert rhs);
        message = builder_to_string(*builder,, temporary_allocator);
    } else #if kind == .PROCEDURE_CALL {
        message = tprint("(%) = (%(%, %)) = false", full_expr, proc_expr, #insert lhs, #insert rhs);
    } else {
        message = tprint("(%) = false", full_expr);
    }

    // We provide 'loc' in case _STACK_TRACE is turned off, but assertion_failed may well
    // look at the stack trace if it is available.
    context.assertion_failed(loc, message);
    debug_break();
    context.handling_assertion_failure = false;

} @NoProfile

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
