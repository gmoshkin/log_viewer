EXE_NAME :: "log_viewer";

/*

TODO:

- when drawing text pane do 2 passes
    - first draw background colors
    - here can draw the time graph and other middle-ground stuff
    - second draw foreground

- here's an idea: instead of filterring I could add undo support, basically just
  store the history of changes and allow switching between them.
  Could even keep track of the undo tree: go back and branch into a new future.
  The ui for navigation could be as simple as 2 arrows: back and forward, but
  if there's a branch there's multiple arrows forward.

- adding text notes to anchors

- serializing the setup, save/restore

- log parsing + semantic highlighting
- preview line at scroll bar anchor hovered over with mouse
- filterring/hiding? I'm not sure yet what I want/need
- status bar
- different panes for different ui elements
- minimap (scroll bar almost does everything now)

*/

main :: () {
    Profile();

    context.logger = my_logger;
    context.print_style.struct_printer = my_struct_printer;

    log("working directory: '%'", get_working_directory());
    from_clipboard := parse_command_line_arguments();

    if run_tests_mode {
        run_tests();
        return;
    }
    // Temporary?
    run_tests();

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

    set_allocators(*escape_code_stats_pool);
    escape_code_stats_allocator = .{pool_allocator_proc, *escape_code_stats_pool};
    init(*escape_code_stats,, escape_code_stats_allocator);

    set_allocators(*the_popup_menu.pool);
    the_popup_menu.allocator = .{pool_allocator_proc, *the_popup_menu.pool};

    Profile();
    load_text_buffer_data(input_from_clipboard);
    Profile();

    reload_main_font();
    load_font("Roboto", *ui_font);

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
mouse_event_handled: bool;
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

ui_font := My_Dynamic_Font.{
    pixel_height = 14,
};

text_pane_rect: Rectangle;
left_column_rect: Rectangle;

scroll_rows := 0.0;
target_scroll_rows := 0.0;
scroll_rows_lerp_factor := 0.5;
scroll_rows_at_click := 0.0;

scroll_columns := 0.0;
target_scroll_columns := 0.0;
scroll_columns_lerp_factor := 0.5;

window_bg_color :: #run hex_color("191919");

draggin_scroll_bar := false;
scroll_bar_rect: Rectangle;
scroll_bar_pad := 1;
scroll_bar_slider_color := #run hex_color("d0d0d0");
scroll_bar_anchor_min_width := 1.7;
scroll_bar_effective_slider_color := #run hex_color("b0b0b0");
scroll_bar_anchor_hover_color := #run hex_color("e0e0e0");

hovered_scroll_bar_anchor_kind: enum { EXPLICIT; SEARCH_MATCH; };
hovered_scroll_bar_anchor_index: s64 = -1;

//
// main update and draw proc
//

update_and_draw_frame :: () -> bool {
    t0 := seconds_since_init();

    array_reset(*redraw_reasons);

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
    mouse_event_handled = false;

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
            request_redraw("mouse left click");
            mouse_at_click = mouse;

            // if text_search_ui_active && !axis_aligned_rectangle_contains(text_search_ui_rect, mouse) {
            //     text_search_ui_active = false;
            // }
        } else if it.key_code == .MOUSE_BUTTON_RIGHT && it.key_pressed {
            request_redraw("mouse right click");
            mouse_at_click = mouse;
        } else if it.key_code == .MOUSE_BUTTON_MIDDLE && it.key_pressed {
            request_redraw("mouse middle click");
            mouse_at_click = mouse;
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
            target_scroll_rows += -6 * it.wheel_delta / cast(float) it.typical_wheel_delta;
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
        }

        else if text_search_ui_open {
            handled := text_search_ui_handle_input_event(it);
            if handled continue;
        }

        if it.key_pressed && it.key_code == .ARROW_UP {
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
        } else if it.key_pressed && it.ctrl_pressed && it.shift_pressed && it.key_code == #char "V" {
            Profile();
            load_text_buffer_data(from_clipboard=true);
            Profile();
        }
    }
    // update vertical scroll
    scroll_rows = lerp(scroll_rows, target_scroll_rows, scroll_rows_lerp_factor);
    if abs(scroll_rows - target_scroll_rows) < 0.001 then scroll_rows = target_scroll_rows;

    // update horizontal scroll
    scroll_columns = lerp(scroll_columns, target_scroll_columns, scroll_columns_lerp_factor);
    if abs(scroll_columns - target_scroll_columns) < 0.001 then scroll_columns = target_scroll_columns;

    // reset these before doing popup menu, because popup menu sets these up
    for *active_anchor_segment it.line_index = -1;

    // update the popup menu
    {
        menu := *the_popup_menu;
        if !draggin_scroll_bar && menu.flags & .OPEN {
            menu.flags &= ~.HAS_MOUSE_FOCUS;
            handled := do_popup_menu(menu, mouse, handle_click=true, do_draw=false);
            if is_click(.MOUSE_BUTTON_LEFT) && !handled {
                menu.flags &= ~.OPEN;
                request_redraw("popup menu closed");
            }
            mouse_event_handled ||= handled;
        }
    }

    //
    // drag scroll bar
    //
    if draggin_scroll_bar {
        mouse_event_handled = true;
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
        if !mouse_event_handled && !has_focus(*the_popup_menu) && axis_aligned_rectangle_contains(left_column_rect, mouse) {
            hover_line_index := screen_position_to_line_index(left_column_rect, mouse.y);
            if hover_line_index >= 0 {
                if hover_line_index != hovered_anchor_button_line {
                    hovered_anchor_button_line = hover_line_index;
                    request_redraw(tprint("anchor buttons at %", #line));
                }

                if is_click(.MOUSE_BUTTON_LEFT) {
                    anchor_button_toggle(hover_line_index);
                } else if is_click(.MOUSE_BUTTON_RIGHT) {
                    anchor_button_open_popup_menu(hover_line_index, mouse);
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
    if !mouse_event_handled && !has_focus(*the_popup_menu) {
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

        if anchor_index != -1 {
            line_index: int;
            if #complete anchor_kind == {
                case .EXPLICIT;     line_index = explicit_anchors[anchor_index].line_index;
                case .SEARCH_MATCH; line_index = search_results.matches[anchor_index].line_index;
            }
            if is_click(.MOUSE_BUTTON_LEFT) {
                target_scroll_rows = xx (line_index - text_pane_row_count / 2);
                request_redraw(tprint("scroll bar anchors at %", #line));
            } else if is_click(.MOUSE_BUTTON_RIGHT) {
                anchor_button_open_popup_menu(line_index, mouse);
            }
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
    base_color := window_bg_color;
    Simp.clear_render_target(base_color.x, base_color.y, base_color.z, 1);

    Simp.set_shader_for_color();

    // draw text pane
    {
        profile_t0 = seconds_since_init();
        draw_the_text_pane(text_pane_rect);
        Profile();

        // draw the side bars to fix the ugly text bleed over
        left_rect := window_rect;
        left_rect.width = left(text_pane_rect);
        draw_axis_aligned_rectangle(left_rect, window_bg_color);

        right_rect := window_rect;
        right_rect.left = right(text_pane_rect);
        right_rect.width -= right_rect.left;
        draw_axis_aligned_rectangle(right_rect, window_bg_color);
    }

    //
    // draw line anchors
    //
    {
        rect := *left_column_rect;
        x_tweak := -3;
        y_tweak := 0;

        parent_top := top(rect) + y_tweak;
        H := main_font.line_height;
        parent_right := right(rect) + x_tweak;

        // hovered anchor segment
        if active_anchor_segment[0].line_index != -1 || active_anchor_segment[1].line_index != -1 {
            above_line_index := active_anchor_segment[0].line_index;
            bellow_line_index := active_anchor_segment[1].line_index;
            // This makes perfect sense!
            assert(above_line_index <= bellow_line_index);

            color := anchor_button_active_color;
            w := 4.0;
            x_middle := parent_right - H / 2.0;
            x := x_middle - w / 2.0;

            y_top := parent_top - (above_line_index - scroll_rows + 0.5) * H + w / 2;
            y_bottom := parent_top - (bellow_line_index - scroll_rows + 0.5) * H - w / 2;
            h := y_top - y_bottom;

            draw_axis_aligned_rectangle(xx x, xx y_bottom, xx w, xx h, color);
        }

        // hovered anchor button
        if hovered_anchor_button_line != -1 {
            color := anchor_button_hover_color;
            pad := 1;
            h := H - 2 * pad;
            w := h;
            x := parent_right - w - pad;

            row_index := hovered_anchor_button_line - scroll_rows;
            y_line := parent_top - (row_index + 1) * H;
            y := y_line + pad;

            // draw_axis_aligned_rectangle(xx (parent_right - H), xx y_line, xx H, xx H, hex_color("000000"));
            draw_hollow_axis_aligned_rectangle(xx x, xx y, xx w, xx h, border = 2, color);
        }

        // active anchor buttons
        {
            color := anchor_button_active_color;
            pad := 4;
            h := H - 2 * pad;
            w := h;
            x := parent_right - w - pad;
            for explicit_anchors {
                row_index := it.line_index - scroll_rows;
                // -1 because want to draw half the button at the top of the screen (bad wording)
                if row_index < -1 continue;
                // LOL this is wrong
                if row_index > xx (rect.height * H) continue;

                y_line := parent_top - (row_index + 1) * H;
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
            mouse_event_handled = true;
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

        // draw active anchor range on scroll bar
        {
            above_line_index := active_anchor_segment[0].line_index;
            bellow_line_index := active_anchor_segment[1].line_index;
            if above_line_index != -1 || bellow_line_index != -1 {
                // Makes complete sense
                assert(above_line_index <= bellow_line_index);

                y_top := rect.top - above_line_index / cast(float) lines_per_scroll_bar_pixel;
                y_bottom := rect.top - bellow_line_index / cast(float) lines_per_scroll_bar_pixel;

                my_w := w / 2.5;
                my_x := x + (w - my_w) / 2;

                color := main_text_pane_dim_background_color;
                draw_axis_aligned_rectangle(xx my_x, y_bottom, xx my_w, y_top - y_bottom, color);
            }
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
            search_match_index := -1;
            if text_search_ui_open
                search_match_index = do_scroll_bar_anchors(scroll_bar_rect, search_results.matches, search_match_color, .DRAW, mouse_in_rect);
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
            handled := draw_text_search_ui(text_search_ui_rect, main_font, handle_click=!mouse_event_handled);
            mouse_event_handled ||= handled;
        }
    }

    // draw the popup menu
    if the_popup_menu.flags & .OPEN {
        do_popup_menu(*the_popup_menu, mouse, handle_click=false, do_draw=true);
    }

    // debuggin pane
    {
        rect := window_rect;
        font := ui_font.regular;
        x := right(window_rect) - 300;
        y := window_rect.top - 4;

        builder: String_Builder; builder.allocator = temp;
        elapsed := seconds_since_init() - t0;
        print(*builder, "% %\n", frame_counter, fmt(elapsed, 6));
        print(*builder, "scroll: %, %\n", fmt(scroll_columns, 1), fmt(scroll_rows, 1));
        print(*builder, "num sources: %\n", text_buffer_all_log_sources.count);
        // print(*builder, "num ranges: %\n", log_ranges_of_source.count);
        // if text_search_ui_open print(*builder, "cursor: %\n", text_input_cursor);
        if text_search_ui_open print(*builder, "search matches: %\n", search_results.matches.count);
        if hovered_scroll_bar_anchor_index != -1 then print(*builder, "% %\n", hovered_scroll_bar_anchor_kind, hovered_scroll_bar_anchor_index);
        // if text_search_ui_open print(*builder, "case-insensitive: %\n", search_results.case_insensitive);
        print(*builder, "t min: ");
        if global_time_range_min != APOLLO_TIME_INVALID then print_time_for_log(*builder, to_calendar(global_time_range_min));
                                                        else print(*builder, "?");
        print(*builder, "\n");
        print(*builder, "t cur: ");
        if global_time_current_line != APOLLO_TIME_INVALID then print_time_for_log(*builder, to_calendar(global_time_current_line));
                                                           else print(*builder, "?");
        print(*builder, "\n");
        print(*builder, "t max: ");
        if global_time_range_max != APOLLO_TIME_INVALID then print_time_for_log(*builder, to_calendar(global_time_range_max));
                                                        else print(*builder, "?");
        print(*builder, "\n");
        for redraw_reasons print(*builder, "%\n", it);

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

    Simp.set_scissor(0, 100, 0, 100);
    Simp.clear_render_target(1, 0, 0, 1);
    Simp.clear_scissor();

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

        // I hate how complicated this got       v this fucking zero ToT
        p0, p1, p2 := get_scroll_bar_triangle(t, 0, y + h / 2);
        hover := triangle_contains(p0, p1, p2, target) || (target.x >= 0 && target.x <= xx parent_rect.width && target.y >= y - slack && target.y <= y + h + slack);

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


    if hover {
        draw_axis_aligned_rectangle(x, y - 1, xx w, 1, hover_color);
        draw_axis_aligned_rectangle(x, y + h, xx w, 1, hover_color);
    }
    draw_axis_aligned_rectangle(xx x, y, xx w, h, color);
    {
        Y := y + h / 2;
        p0, p1, p2 := get_scroll_bar_triangle(t, x, Y);
        if hover {
            draw_triangle(p0 + .{ 2, 0 }, p1 + .{ -1.333333, -2 }, p2 + .{ -1.333333, 2 }, hover_color);
        }
        draw_triangle(p0, p1, p2, color);
    }

}

get_scroll_bar_triangle :: ($$t: float, x: float, y: float, $x_tweak := 2.0) -> (Vector2, Vector2, Vector2) #expand {
    p0 := Vector2.{x - x_tweak, y};
    p1 := p0 + .{x_tweak - t, -t/2};
    p2 := p0 + .{x_tweak - t,  t/2};
    return p0, p1, p2;
}

//
// text pane stuff
//

main_text_pane_text_color           :: #run hex_color("e0e0e0");
main_text_pane_dim_text_color       :: #run hex_color("909090");
main_text_pane_background_color     :: #run hex_color("202020");
main_text_pane_dim_background_color :: #run hex_color("404040");

// @DEBUG
global_time_range_min := APOLLO_TIME_INVALID;
global_time_range_max := APOLLO_TIME_INVALID;
global_time_current_line := APOLLO_TIME_INVALID;

draw_the_text_pane :: (rect: Rectangle) {
    text_color       := main_text_pane_text_color;
    background_color := main_text_pane_background_color;

    // background
    {
        h := main_font.line_height;

        x := left(rect);
        y_top := cast(float) top(rect);
        if scroll_rows < 0 then y_top += scroll_rows * h;

        y_bottom := cast(float) bottom(rect);
        text_height := (text_buffer_line_infos.count - scroll_rows) * h;
        if text_height < xx height(rect) then y_bottom = top(rect) - text_height;


        w := width(rect);
        H := y_top - y_bottom;
        draw_axis_aligned_rectangle(xx x, xx y_bottom, xx w, xx H, background_color);
    }

    hover_line_index := -1;
    if !has_focus(*the_popup_menu) && axis_aligned_rectangle_contains(rect, mouse) {
        hover_line_index = screen_position_to_line_index(rect, mouse.y);
    }

    first_line := S64_MAX;
    last_line := -1;

    // text
    {
        tail := text_buffer_data;

        h := main_font.line_height;

        text_x_tweak := 4.0;
        pane_width_in_characters := (rect.width - text_x_tweak) / main_font.mono_width;

        x := rect.left + text_x_tweak;
        y_top := rect.top + (scroll_rows - 1) * h;
        text_y_tweak := -(main_font.typical_descender + main_font.max_descender) / 2.0;

        current_ansi_style := Style.{ fg_color = text_color };
        override_ansi_style: Style;
        anchor_segment_first := active_anchor_segment[0].line_index;
        anchor_segment_last := active_anchor_segment[1].line_index;

        search_matches_cursor := 0;
        line_index := 0;
        first_line = max(cast(int) floor(scroll_rows), 0);
        last_line = min(first_line + 1 + cast(int) floor(rect.height / cast(float) h), text_buffer_line_infos.count - 1);
        for line_index: first_line..last_line {
            info := *text_buffer_line_infos[line_index];
            line_end := ifx line_index < text_buffer_line_infos.count - 1 then text_buffer_line_infos[line_index + 1].line_offset
                                                                          else text_buffer_data.count;
            line_start := info.line_offset;
            line := slice(text_buffer_data, line_start, line_end - line_start);
            if line.count > 0 && line[line.count - 1] == #char "\n" then line.count -= 1;

            y := y_top - (line_index * h);

            first_line = min(first_line, line_index);
            last_line = max(last_line, line_index);

            // handle log line info
            color := text_color;
            if info.source_id != SOURCE_ID_UNKNOWN {
                color = get_log_source_color(info.source_id);

                source := text_buffer_all_log_sources[info.source_id];
                if line_index == hover_line_index && (xx (info.source_start + source.count) > scroll_columns) {
                    x_start := x + (info.source_start - scroll_columns) * main_font.mono_width;
                    x_end := min(x_start + source.count * main_font.mono_width, xx right(rect));
                    x_start = max(x_start, xx left(rect));

                    if mouse.x >= x_start && mouse.x <= x_end {
                        w := x_end - x_start;
                        draw_hollow_axis_aligned_rectangle(xx x_start, xx y, xx w, xx main_font.line_height, 2, color_gray);

                        if !mouse_event_handled && is_click(.MOUSE_BUTTON_RIGHT) {
                            log_source_open_popup_menu(info, mouse);
                        }
                    }
                }
            }


            // handle anchor segment
            inside_anchor_segment := (line_index >= anchor_segment_first) && (line_index <= anchor_segment_last);
            if inside_anchor_segment {
                color = main_text_pane_dim_text_color;
                override_ansi_style.fg_color = color;
                override_ansi_style.bg_color = main_text_pane_dim_background_color;

                draw_axis_aligned_rectangle(xx rect.left, xx y, xx rect.width, xx main_font.line_height, main_text_pane_dim_background_color);
            } else {
                override_ansi_style = .{};
            }

            n_columns_to_skip := cast(int) floor(scroll_columns);
            x_tweak := (scroll_columns - n_columns_to_skip) * main_font.mono_width;

            // if line_index % 2 == 0
            //     draw_axis_aligned_rectangle(xx x, xx y, xx rect.width, xx main_font.line_height, hex_color("005050"));

            if xx line.count > scroll_columns {
                font := main_font.regular;
                if line_index == hover_line_index {
                    font = main_font.bold;
                }

                if info.escape_codes_count != 0 {
                    codes := array_view(text_buffer_escape_code_infos, info.escape_codes_start, info.escape_codes_count);
                    draw_text_line_with_ansi_escape_codes(main_font, line, n_columns_to_skip, xx pane_width_in_characters,
                                                          x, -x_tweak, y, text_y_tweak, color, codes, *current_ansi_style, override_ansi_style);
                } else {
                    line = advance(line, n_columns_to_skip);
                    // I'm sleepy and this doesn't work ToT
                    line.count = min(line.count, xx pane_width_in_characters + 1);

                    // TODO: tabs handling (I fucking hate tabs!!!!)
                    w_text := Simp.prepare_text(font, line);
                    // This fails for unicode!
                    // assert(w_text == main_font.mono_width * line.count);

                    Simp.draw_prepared_text(font, xx (x - x_tweak), xx (y + text_y_tweak), color);
                }
            }

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

            // handle search match
            if text_search_ui_open
                // TODO @INCOMPLETE draw all matches, not just the first ones
                draw_search_match_border(rect, main_font, text_x_tweak, y, line_index, *search_matches_cursor);

        }

    }

    global_time_range_min = APOLLO_TIME_INVALID;
    global_time_range_max = APOLLO_TIME_INVALID;
    global_time_current_line = APOLLO_TIME_INVALID;

    // time stamp graph
    {
        h := main_font.line_height;
        y_top := rect.top + (scroll_rows - 0.5) * h;

        time_range_min := APOLLO_TIME_INVALID;
        time_range_max := APOLLO_TIME_INVALID;
        for first_line..last_line {
            info := *text_buffer_line_infos[it];
            if info.source_id == SOURCE_ID_UNKNOWN continue;
            if info.time_stamp.year == 0 continue;

            time := calendar_to_apollo(info.time_stamp);

            if it == hover_line_index then global_time_current_line = time;

            if time_range_min == APOLLO_TIME_INVALID then time_range_min = time;
            time_range_min = min(time_range_min, time);
            if time_range_max == APOLLO_TIME_INVALID then time_range_max = time;
            time_range_max = max(time_range_max, time);
        }

        global_time_range_min = time_range_min;
        global_time_range_max = time_range_max;

        time_range := to_float64_seconds(time_range_max - time_range_min);

        color: Vector4;
        if time_range < 0.1 {
            color_t := clamp(time_range, 0, 0.1) / 0.1;
            color = lerp(color_cyan, color_orange, xx color_t);
        } else {
            color_t := (clamp(time_range, 0.1, 1.0) - 0.1) / 0.9;
            color = lerp(color_orange, color_red, xx color_t);
        }

        x_prev := cast(float) left(rect);
        y_prev := y_top;
        seen_time_stamp := false;
        for line_index: first_line..last_line {
            y := y_top - line_index * h;

            info := *text_buffer_line_infos[line_index];
            if info.source_id == SOURCE_ID_UNKNOWN continue;
            if info.time_stamp.year == 0 continue;

            time := calendar_to_apollo(info.time_stamp);
            time_adjusted := time - time_range_min;
            adjusted_seconds := to_float64_seconds(time_adjusted);
            t := adjusted_seconds / time_range;

            if isnan(t) then t = 0.5;

            x := cast(float, left(rect) + width(rect) * t);

            if !seen_time_stamp {
                x_prev, y_prev = x, y;
                seen_time_stamp = true;
            }

            draw_fat_line(.{x_prev, y_prev}, .{x, y}, 2.5, color);

            x_prev, y_prev = x, y;
        }
    }
}

draw_text_line_with_ansi_escape_codes :: (font_set: My_Dynamic_Font, text: string,
                                          n_columns_to_skip: int, max_characters: int,
                                          left: float, text_x_tweak: float,
                                          bottom: float, text_y_tweak: float,
                                          default_color: Vector4, codes: [] Escape_Code_Info,
                                          current_style: *Style, override_style: Style)
{
    current_invisible_before: u16 = 0;

    segments: [..] struct { start: u16; count: u16; invisible_before: u16; style: Style; };
    segments.allocator = temp;
    array_reserve(*segments, codes.count + 1);

    cursor := 0;
    for codes {
        assert(cursor < text.count);
        segment_length := it.start - cursor;
        if segment_length != 0 {
            array_add(*segments, .{xx cursor, xx segment_length, current_invisible_before, current_style.*});
        }
        current_invisible_before += it.count;
        cursor = it.start + it.count;
        evaluate_style_sequence(it.sequence, current_style, default_color);
    }
    assert(cursor <= text.count);
    array_add(*segments, .{xx cursor, xx (text.count - cursor), current_invisible_before, current_style.*});

    i := 0;
    while i < segments.count {
        it := *segments[i];
        visible_start := it.start - it.invisible_before;
        if visible_start + it.count <= n_columns_to_skip { i += 1; continue; }
        to_cut := n_columns_to_skip - visible_start;
        if to_cut < 0 { i += 1; continue; }

        it.start += xx to_cut;
        it.count -= xx to_cut;
        break;
    }

    if i >= segments.count return;

    line_height := font_set.line_height;
    character_width := font_set.mono_width;

    stop := n_columns_to_skip + max_characters;
    while i < segments.count {
        defer i += 1;
        it := segments[i];

        // truncate text to fit in screen
        visible_start := it.start - it.invisible_before;
        if visible_start >= stop break;
        visible_end := visible_start + it.count;
        to_cut := visible_end - stop;
        if to_cut > 0 then it.count -= xx to_cut;

        x := left + character_width * (visible_start - n_columns_to_skip) + text_x_tweak;

        // choose color
        fg_color := it.style.fg_color;
        if override_style.fg_color.w > 0 then fg_color = override_style.fg_color;
        bg_color := it.style.bg_color;
        if override_style.bg_color.w > 0 then bg_color = override_style.bg_color;
        if it.style.attributes & .INVERSE then inline Swap(*fg_color, *bg_color);

        // draw background
        if bg_color.w > 0 {
            w := character_width * it.count;
            draw_axis_aligned_rectangle(xx x, xx bottom, xx w, xx line_height, bg_color);
        }

        font := font_for_attributes(font_set, it.style.attributes);

        // TODO: tabs handling (I fucking hate tabs!!!!)
        segment_text := slice(text, it.start, it.count);
        w_text := Simp.prepare_text(font, segment_text);
        // This fails for unicode!
        // assert(w_text == main_font.mono_width * line.count);

        Simp.draw_prepared_text(font, xx x, xx (bottom + text_y_tweak), fg_color);
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
// string owned by `text_buffer_data`
text_buffer_all_log_sources: [..] string;
// string owned by `text_buffer_data`
text_buffer_log_sources_to_pid: Table(string, s32);
text_buffer_line_infos: [..] Log_Line_Info;
text_buffer_escape_code_infos: [..] Escape_Code_Info;
merged_log_sources: [..] Merge_Info;

Merge_Info :: struct { from, to: u8; }

Log_Line_Info :: struct {
    line_offset: s64;
    time_stamp: Calendar_Time;
    source_id: u8 = SOURCE_ID_UNKNOWN;
    source_start: u8;
    escape_codes_start: s16;
    escape_codes_count: s16;
    pid: s32 = -1;
}

Escape_Code_Info :: struct {
    // relative to line start
    start: s32;
    count: u8;
    sequence: Small_Escape_Sequence;
}
#assert size_of(Escape_Code_Info) == 16;

color_red :: #run hex_color("db0011");
color_green :: #run hex_color("00c52c");
color_blue :: #run hex_color("0069cb");
color_coral :: #run hex_color("ff8080");
color_yellow :: #run hex_color("ffdf00");
color_cyan :: #run hex_color("208c73");
color_magenta :: #run hex_color("ff00bb");
color_orange :: #run hex_color("ff6b00");
color_baby_blue :: #run hex_color("6bc8f2");
color_purple :: #run hex_color("a000ff");
color_white :: #run hex_color("ffffff");
color_brown :: #run hex_color("973f00");
color_black :: #run hex_color("000000");
color_gray :: #run hex_color("707070");

log_source_color_scheme := Vector4.[
    color_coral,
    color_yellow,
    color_cyan,
    color_magenta,
    color_orange,
    color_baby_blue,
    color_purple,
    color_red,
    color_green,
    color_blue,
    color_white,
    color_brown,
];

get_log_source_color :: (source_id: u8) -> Vector4 {
    if source_id == SOURCE_ID_UNKNOWN return main_text_pane_text_color;

    for merged_log_sources if it.from == source_id return get_log_source_color(it.to);

    return log_source_color_scheme[source_id % log_source_color_scheme.count];
}

log_source_open_popup_menu :: (info: *Log_Line_Info, mouse: Vector2) {
    menu := open_the_popup_menu(mouse, log_line_popup_menu_callback, info.source_id);

    for log_source, source_id: text_buffer_all_log_sources {
        // Skip self
        if source_id == info.source_id continue;

        if !ok_to_merge(merged_log_sources, from=xx source_id, to=info.source_id) continue;

        color := get_log_source_color(xx source_id);
        pids := table_find_multiple(*text_buffer_log_sources_to_pid, log_source);
        popup_menu_push_item(menu, "Merge with % (pid: %)", log_source, pids, id=source_id, icon=.{color, 8.0, .SQUARE});
    }
}

Log_Range :: struct {
    source_id: u8;
    start_index: int;
}
log_ranges_of_source: [..] Log_Range;

SOURCE_ID_UNKNOWN :: cast(u8) 0xff;

load_text_buffer_data :: (from_clipboard := false) {
    mark := get_temporary_storage_mark();
    defer set_temporary_storage_mark(mark);

    new_data: string;
    if from_clipboard {
        log("reading text data from clipboard");
        new_data = os_clipboard_get_text();
    } else {
        file_path := input_file_full_path;
        if !input_file_full_path {
            file_path = tprint("%/sample_log.txt", assets_directory);
        }
        log("reading file '%'", file_path);
        new_data=, ok := read_entire_file(file_path);
        assert(ok);
    }

    free(text_buffer_data);
    text_buffer_data = new_data;

    process_text_buffer_data();
}

process_text_buffer_data :: () {
    // TODO: keeping history, undo/redo, etc.

    if contains(text_buffer_data, #char "\r") {
        // FIXME could also replace this in place...
        new_data := replace(text_buffer_data, "\r\n", "\n");
        free(text_buffer_data);
        text_buffer_data = new_data;
        replace_in_place(text_buffer_data, #char "\r", #char "\n");
    }

    array_reset_keeping_memory(*text_buffer_all_log_sources);
    // keeps memory
    table_reset(*text_buffer_log_sources_to_pid);
    array_reset_keeping_memory(*merged_log_sources);
    array_reserve(*text_buffer_all_log_sources, SOURCE_ID_UNKNOWN);
    array_reset_keeping_memory(*text_buffer_line_infos);
    array_reset_keeping_memory(*log_ranges_of_source);
    array_reset_keeping_memory(*text_buffer_escape_code_infos);

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

        // line_offset := line.data - text_buffer_data.data;
        info.escape_codes_start = xx text_buffer_escape_code_infos.count;
        parse_ansi_escape_codes(line, 0, *text_buffer_escape_code_infos);
        info.escape_codes_count = xx (text_buffer_escape_code_infos.count - info.escape_codes_start);

        if !ok continue;

    }

    // Add a dummy range start at the end for convenience
    array_add(*log_ranges_of_source, .{ SOURCE_ID_UNKNOWN, line_index });

    for to, to_id: text_buffer_all_log_sources for from, from_id: text_buffer_all_log_sources {
        if to_id == from_id continue;
        to_pids := table_find_multiple(*text_buffer_log_sources_to_pid, to);
        from_pids := table_find_multiple(*text_buffer_log_sources_to_pid, from);
        for from_pid: from_pids for to_pid: to_pids {
            if from_pid != to_pid continue;
            if !ok_to_merge(merged_log_sources, from=xx from_id, to=xx to_id) continue;
            array_add(*merged_log_sources, .{to=xx to_id, from=xx from_id});
            continue from;
        }
    }

    // line_index := 0;
    // while line_index < text_buffer_line_infos.count {
    //     defer line_index += 1000;
    //     array_add(*explicit_anchors, .{ line_index });
    // }

    log("line count: %", text_buffer_line_infos.count);
    log("max line length: %", max_line_length);
    log("escape code count: % (% unique)", text_buffer_escape_code_infos.count, escape_code_stats.count);

    // for escape_code_stats {
    //     log("'%': %, seen % times", cast(Ascii_Or_Hex) it_index, parse_escape_sequence(it_index), it);
    // }

    if search_results.matches {
        update_text_buffer_search_results(search_results.search_string);
    }
}

text_buffer_data_remove_range :: (first_line: s64, last_line: s64) {
    assert(0 <= first_line, "%", first_line);
    assert(first_line <= last_line, "% v %", first_line, last_line);
    assert(last_line <= text_buffer_line_infos.count, "% v %", last_line, text_buffer_line_infos.count);

    n_lines_removed := last_line - first_line + 1;
    for *explicit_anchors {
        if it.line_index < first_line continue;
        if it.line_index <= last_line {
            remove it;
        } else {
            it.line_index -= n_lines_removed;
        }
    }

    if scroll_rows > xx first_line {
        scroll_rows -= n_lines_removed;
        target_scroll_rows -= n_lines_removed;
    }

    start := text_buffer_line_infos[first_line].line_offset;
    end := ifx last_line >= text_buffer_line_infos.count - 1 then text_buffer_data.count
                                                             else text_buffer_line_infos[last_line + 1].line_offset;

    moved := text_buffer_data.count - end;
    removed := end - start;
    memcpy(text_buffer_data.data + start, text_buffer_data.data + end, moved);
    text_buffer_data.count -= removed;

    process_text_buffer_data();
}

parse_text_buffer_log_line :: (line: string, info: *Log_Line_Info) -> bool {
    cursor := 0;

    // skip whitespace
    while cursor < line.count && inline is_space(line[cursor]) { cursor += 1; }
    if cursor >= line.count return false;

    //
    // parse source
    //
    // example: `default_2_3    |`
    //           ~~~~~~~~~~~
    //
    source_start := cursor;
    while cursor < line.count {
        c := line[cursor];
        if !(is_alpha(c) || is_digit(c) || c == #char ":" || c == #char "_") break;
        cursor += 1;
    }
    if cursor == source_start return false;

    source_count := cursor - source_start;

    // skip whitespace
    while cursor < line.count && inline is_space(line[cursor]) { cursor += 1; }

    if cursor >= line.count return false;
    if line[cursor] != #char "|" return false;
    cursor += 1;

    source := slice(line, source_start, source_count);

    // skip whitespace
    while cursor < line.count && inline is_space(line[cursor]) { cursor += 1; }

    //
    // parse time stamp
    //

    time_stamp_start := cursor;
    time_stamp, status, tail := parse_date_time_stamp(advance(line, cursor));
    if status != .FULL {
        source_is_not_number := false;
        for source if !inline is_digit(it) { source_is_not_number = true; break; }

        // @HACK I want to ingore lines like ` 123 |  let compilation = error;`
        // but keep lines which come from audit (why do I even bother?)
        if source_is_not_number {
            source_id := add_source(*text_buffer_all_log_sources, source);
            info.source_start = xx source_start;
            info.source_id = source_id;
        }

        // TODO: parse the json log format

        return false;
    }

    source_id := add_source(*text_buffer_all_log_sources, source);
    info.source_start = xx source_start;
    info.source_id = source_id;

    cursor = ifx tail then tail.data - line.data else line.count;

    info.time_stamp = time_stamp;

    //
    // parse pid
    //

    // skip whitespace
    while cursor < line.count && inline is_space(line[cursor]) { cursor += 1; }

    // `[`
    if line.count - cursor < 1 return false;
    lb := line[cursor]; cursor += 1;
    if lb != #char "[" return false;

    // pid
    pid_start := cursor;
    pid: s32;
    while cursor < line.count {
        d := line[cursor];
        if !inline is_digit(d) break;
        cursor += 1;
        pid = pid * 10 + (d - #char "0");
    }
    if cursor == pid_start return false;

    // `]`
    if line.count - cursor < 1 return false;
    rb := line[cursor]; cursor += 1;
    if rb != #char "]" return false;

    info.pid = pid;
    already_seen := false;
    for table_find_multiple(*text_buffer_log_sources_to_pid, source) {
        if it == pid {
            already_seen = true;
            break;
        }
    }
    if !already_seen
        table_add(*text_buffer_log_sources_to_pid, source, pid);

    return true;
}

add_source :: (sources: *[..] string, source: string) -> source_id: u8 {
    for sources.* {
        if it == source return xx it_index;
    }

    if sources.count == SOURCE_ID_UNKNOWN return SOURCE_ID_UNKNOWN;

    array_add(sources, source);
    return xx (sources.count - 1);
}

ok_to_merge :: (merges: [] Merge_Info, from: u8, to: u8) -> ok: bool {
    // Merging these 2 would lead to an infinite loop
    if detect_cycle(merged_log_sources, from=from, to=to) return false;

    // Skip ones that are already merged somewhere, don't merge them to anything else
    for merge: merged_log_sources if merge.from == from return false;

    return true;
}

detect_cycle :: (merges: [] Merge_Info, from: u8, to: u8) -> found_cycle: bool {
    for merges {
        if it.to != from continue;
        if it.from == to return true;
        if detect_cycle(merges, it.from, to) return true;
    }
    return false;
}


log_line_popup_menu_callback :: (menu: *Popup_Menu, event: Popup_Menu_Event) {
    assert(menu.callback_data.type == type_info(u8));
    this_source_id := cast(*u8, menu.callback_data.value_pointer).*;

    if event == .CLICK {
        id := menu.items[menu.hovered_item].id;
        array_add(*merged_log_sources, .{to=xx this_source_id, from=xx id});
        log("merged sources % and %", this_source_id, id);
    }
}

//
// text search stuff
//

Search_Results :: struct {
    search_string_storage: [MAX_SEARCH_STRING_LENGTH + 1] u8;
    search_string: string;
    case_insensitive := false;
    matches: [..] Search_Match_Info;
}
MAX_SEARCH_STRING_LENGTH :: 255;

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
    search_results.search_string_storage[search_string.count] = 0; // XXX I don't really need this...
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
    italic: *Simp.Dynamic_Font;
    bold_italic: *Simp.Dynamic_Font;
    pixel_height: int;
    mono_width: int;
    line_height: int;
}

font_for_attributes :: (font: My_Dynamic_Font, attributes: Style_Attributes) -> *Simp.Dynamic_Font {
    if attributes == {
        case .BOLD;           return font.bold;
        case .ITALIC;         return font.italic;
        case .BOLD | .ITALIC; return font.bold_italic;
    }
    return font.regular;
}

reload_main_font :: () {
    load_font("Codetta", *main_font);
}

load_font :: (name: string, font: *My_Dynamic_Font) {
    assert(font.pixel_height >= 0);

    regular_name := tprint("%-Regular.ttf", name);
    log("loading '%' at size %", regular_name, font.pixel_height);
    font.regular = Simp.get_font_at_size(assets_directory, regular_name, font.pixel_height);

    bold_name := tprint("%-Bold.ttf", name);
    log("loading '%' at size %", bold_name, font.pixel_height);
    font.bold = Simp.get_font_at_size(assets_directory, bold_name, font.pixel_height);

    italic_name := tprint("%-Italic.ttf", name);
    log("loading '%' at size %", italic_name, font.pixel_height);
    font.italic = Simp.get_font_at_size(assets_directory, italic_name, font.pixel_height);

    bold_italic_name := tprint("%-BoldItalic.ttf", name);
    log("loading '%' at size %", bold_italic_name, font.pixel_height);
    font.bold_italic = Simp.get_font_at_size(assets_directory, bold_italic_name, font.pixel_height);

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

text_search_ui_background_color :: #run hex_color("181818");
text_search_ui_border_color :: #run hex_color("303030");
text_search_ui_cursor_color :: #run hex_color("ffffff");
text_search_ui_text_color :: #run hex_color("ffffff");
text_search_ui_border_width :: 3.0;

text_search_input := Text_Input_State.{
    max_length = MAX_SEARCH_STRING_LENGTH,
};

open_text_search_ui :: () {
    text_search_ui_open = true;
}

close_text_search_ui :: () {
    text_search_ui_open = false;
}

text_search_ui_handle_input_event :: (event: Input.Event) -> handled: bool {
    status := text_input_handle_event(*text_search_input, event);
    if !status return false;

    if status & .TEXT_CHANGED {
        update_text_buffer_search_results(xx text_search_input.buffer);
    }

    if status & .ENTER_HIT {
        forwards := !(status & .SHIFT_PRESSED);
        jump_to_next_search_match(forwards);
    }

    if status & .CLOSED {
        close_text_search_ui();
    }

    request_redraw("text search ui update");

    return xx status;
}

jump_to_next_search_match :: (forwards: bool) {
    n_lines_per_screen := height(text_pane_rect) / cast(float) main_font.line_height;
    jump_destination_row_offset := n_lines_per_screen / 2.0 - 3;
    current_line_index := cast(int) floor(target_scroll_rows + jump_destination_row_offset);

    // @ROBUSTNESS assuming search_matches are ordered
    matched_line_index := -1;
    if forwards {
        for search_results.matches {
            if it.line_index > current_line_index {
                matched_line_index = it.line_index;
                break;
            }
        }
    } else {
        for < search_results.matches {
            if it.line_index < current_line_index {
                matched_line_index = it.line_index;
                break;
            }
        }
    }

    if matched_line_index >= 0 {
        target_scroll_rows = matched_line_index - jump_destination_row_offset;
    }
}

draw_text_search_ui :: (rect: Rectangle, font: My_Dynamic_Font, handle_click: bool) -> click_handled: bool {
    draw_axis_aligned_rectangle(rect, text_search_ui_background_color);
    draw_hollow_axis_aligned_rectangle(xx rect.left, xx bottom(rect), xx rect.width, xx rect.height,
                                       border = text_search_ui_border_width, text_search_ui_border_color);

    border_width := text_search_ui_border_width;
    text_x_tweak := border_width * 2 + 2;
    text_y_tweak := border_width * 2 + 2;
    text_x := rect.left + text_x_tweak;
    text_y := bottom(rect) + text_y_tweak;

    click_handled := draw_text_input(*text_search_input, text_x, text_y, xx width(rect), font.regular, text_search_ui_text_color, handle_click);

    // do buttons
    if search_results.matches {
        fg_color := text_search_ui_text_color;
        bg_color := text_search_ui_background_color;

        size := cast(float) height(rect);
        pad := border_width;

        x := right(rect) + pad;
        y := cast(float) bottom(rect);

        click := do_simple_button(x, y, size, size, border_width, Icon_Info.{fg_color, size * .6, .TRIANGLE_LEFT}, bg_color, handle_click);
        if click {
            jump_to_next_search_match(forwards=false);
            click_handled = true;
        }

        x += size + pad;
        click = do_simple_button(x, y, size, size, border_width, Icon_Info.{fg_color, size * .6, .TRIANGLE_RIGHT}, bg_color, handle_click);
        if click {
            jump_to_next_search_match(forwards=true);
            click_handled = true;
        }
    }

    return click_handled;
}

//
// anchor buttons
//

anchor_button_active_color  := #run hex_color("4050d0");
anchor_button_hover_color   := #run hex_color("404040");
anchor_line_highlight_color := #run hex_color("404040");
explicit_anchors: [..] Anchor;
Anchor :: struct {
    line_index: s64;
}
hovered_anchor_button_line: s64 = -1;
active_anchor_segment: [2] Anchor;

anchor_button_toggle :: (line_index: int) {
    anchor_index := -1;
    for explicit_anchors if it.line_index == line_index {
        anchor_index = it_index;
        break;
    }

    // FIXME: just use procedures which preserve order
    if anchor_index != -1 {
        array_unordered_remove_by_index(*explicit_anchors, anchor_index);
    } else {
        array_add(*explicit_anchors, .{line_index});
    }
    quick_sort(explicit_anchors, (l, r) => l.line_index - r.line_index);

    request_redraw("anchor button toggle");
}

anchor_button_open_popup_menu :: (line_index: int, mouse: Vector2) {
    anchor := Anchor.{-1};
    anchor_above := Anchor.{-1};   // I'm not stupid, this line is above
    anchor_bellow := Anchor.{-1};  // this one on the monitor
    for explicit_anchors {
        if it.line_index < line_index {
            anchor_above = it;
        } else if it.line_index > line_index {
            if anchor_bellow.line_index == -1 then anchor_bellow = it;
        } else {
            anchor = it;
        }
    }

    data := Anchor_Button_Popup_Menu_Callback_Data.{line_index, anchor, anchor_above, anchor_bellow};
    menu := open_the_popup_menu(mouse, anchor_button_popup_menu_callback, data);

    using Anchor_Button_Popup_Menu_Item_Id;
    active := (anchor.line_index != -1);
    if active then popup_menu_push_item(menu, "Remove anchor", id=xx TOGGLE);
              else popup_menu_push_item(menu, "Add anchor", id=xx TOGGLE);

    popup_menu_push_item(menu, "Delete 1 line", id=xx DELETE_1_LINE);

    if anchor_above.line_index != -1 then popup_menu_push_item(menu, "Delete lines up (to anchor)", id=xx DELETE_LINES_UP);
                                     else popup_menu_push_item(menu, "Delete lines up", id=xx DELETE_LINES_UP);

    if anchor_bellow.line_index != -1 then popup_menu_push_item(menu, "Delete lines down (to anchor)", id=xx DELETE_LINES_DOWN);
                                      else popup_menu_push_item(menu, "Delete lines down", id=xx DELETE_LINES_DOWN);

    request_redraw("popup menu opened");
}

Anchor_Button_Popup_Menu_Callback_Data :: struct {
    line_index: int;
    anchor: Anchor;
    anchor_above: Anchor;
    anchor_bellow: Anchor;
}

Anchor_Button_Popup_Menu_Item_Id :: enum {
    TOGGLE;
    DELETE_1_LINE;
    DELETE_LINES_UP;
    DELETE_LINES_DOWN;
}

anchor_button_popup_menu_callback :: (menu: *Popup_Menu, event: Popup_Menu_Event) {
    assert(menu.callback_data.type == type_info(Anchor_Button_Popup_Menu_Callback_Data));
    data := cast(*Anchor_Button_Popup_Menu_Callback_Data) menu.callback_data.value_pointer;

    first, last: Anchor;

    item := menu.items[menu.hovered_item];
    command := cast(Anchor_Button_Popup_Menu_Item_Id) item.id;
    if #complete command == {
        case .TOGGLE;
            if event == .CLICK
                anchor_button_toggle(data.line_index);

        case .DELETE_1_LINE;
            first = Anchor.{data.line_index};
            last = Anchor.{data.line_index};

        case .DELETE_LINES_UP;
            first = data.anchor_above;
            if first.line_index == -1 then first.line_index = 0;
            last = Anchor.{data.line_index};

        case .DELETE_LINES_DOWN;
            first = Anchor.{data.line_index};
            last = data.anchor_bellow;
            if last.line_index == -1 then last.line_index = text_buffer_line_infos.count - 1;
    }

    if command == .DELETE_1_LINE || command == .DELETE_LINES_UP || command == .DELETE_LINES_DOWN {
        active_anchor_segment[0] = first;
        active_anchor_segment[1] = last;

        if event == .CLICK
            text_buffer_data_remove_range(first.line_index, last.line_index);
    }
}

//
// ui primitives
//

Popup_Menu :: struct {
    top: float;
    left: float;
    items: [..] Popup_Menu_Item;
    hovered_item: s16 = -1;
    flags: enum_flags { OPEN; HAS_MOUSE_FOCUS; };

    callback: Popup_Menu_Callback;
    callback_data: Any;

    pool: Pool;
    allocator: Allocator;
}

Popup_Menu_Callback :: #type (menu: *Popup_Menu, event: Popup_Menu_Event);
Popup_Menu_Event :: enum { CLICK; HOVER; }

the_popup_menu: Popup_Menu;

Popup_Menu_Item :: struct {
    icon: Icon_Info;
    text: string;
    id: int;
}

Icon_Info :: struct {
    // TODO: support images
    color: Vector4;
    size: float;
    type: enum {
        NONE;
        SQUARE;
        TRIANGLE_LEFT;
        TRIANGLE_RIGHT;
        TRIANGLE_UP;
        TRIANGLE_DOWN;
    }
}

popup_menu_border_color :: text_search_ui_border_color;
popup_menu_border_width :: 2.0;
popup_menu_hovered_item_bg_color :: #run hex_color("505050");
popup_menu_item_bg_color :: text_search_ui_background_color;
popup_menu_item_text_color :: main_text_pane_text_color;

has_focus :: (menu: *Popup_Menu) -> bool #expand {
    return menu.flags & .HAS_MOUSE_FOCUS != 0;
}

open_the_popup_menu :: inline (at: Vector2, callback: Popup_Menu_Callback) -> *Popup_Menu {
    return open_the_popup_menu(at, callback, null);
}

open_the_popup_menu :: (at: Vector2, callback: Popup_Menu_Callback, callback_data: $T) -> *Popup_Menu {
    menu := *the_popup_menu;
    array_reset(*menu.items);
    reset(*menu.pool);

    menu.callback = callback;
    info :: type_info(T);
    #if info.type == .POINTER || info.type == .STRING {
        menu.callback_data = callback_data;
    } else {
        menu.callback_data.type = info;
        menu.callback_data.value_pointer = get(*menu.pool, size_of(T));
        cast(*T, menu.callback_data.value_pointer).* = callback_data;
    }

    menu.left = at.x;
    menu.top = at.y;
    menu.flags |= .OPEN;

    return menu;
}

popup_menu_push_item :: (menu: *Popup_Menu, format: string, args: .. Any, id := -1, icon := Icon_Info.{}) {
    text := sprint(format, ..args,, menu.allocator);
    array_add(*menu.items, Popup_Menu_Item.{text = text, id = id, icon = icon});
}

popup_menu_handle_click :: (menu: *Popup_Menu) {
    item := menu.hovered_item;

    if menu.callback {
        menu.callback(menu, .CLICK);
    }

    menu.flags &= ~(.OPEN | .HAS_MOUSE_FOCUS);
}

do_popup_menu :: (menu: *Popup_Menu, mouse: Vector2, handle_click: bool, $do_draw := false) -> input_handled: bool {
    if !menu.items {
        // Somebody opened an empty menu, just close it immediately
        menu.flags &= ~(.OPEN | .HAS_MOUSE_FOCUS);
        return false;
    }

    font := ui_font;
    assert(menu.flags & .OPEN != 0);

    text_color := main_text_pane_text_color;

    h := font.line_height;
    text_y_tweak := -(font.typical_descender + font.max_descender) / 2;
    x_pad := text_y_tweak;
    text_x_tweak := h + x_pad;

    text_w_max := 0;
    for menu.items {
        text_w := Simp.prepare_text(font.regular, it.text);
        text_w_max = max(text_w, text_w_max);
    }

    b := popup_menu_border_width;
    X := menu.left;
    H := h * menu.items.count;
    Y := menu.top - H + 1;
    W := text_w_max + text_x_tweak + x_pad;

    overflow := 0 - (Y - b);                if overflow > 0 { menu.top += overflow; Y += overflow; }
    overflow = (Y + H + b) - window_size.y; if overflow > 0 { menu.top -= overflow; Y -= overflow; }
    overflow = 0 - (X - b);                 if overflow > 0 { menu.left += overflow; X += overflow; }
    overflow = (X + W + b) - window_size.x; if overflow > 0 { menu.left -= overflow; X -= overflow; }

    //
    // draw background rect
    //
    #if do_draw {
        draw_axis_aligned_rectangle(xx X, xx Y, xx W, xx H, popup_menu_item_bg_color);
        draw_hollow_axis_aligned_rectangle(X - b, Y - b, W + 2 * b, H + 2 * b, b, popup_menu_border_color);
    }

    click := handle_click && is_click(.MOUSE_BUTTON_LEFT);
    if axis_aligned_rectangle_contains(X, Y, xx W, xx H, mouse) {
        menu.flags |= .HAS_MOUSE_FOCUS;
    }

    handled := false;

    // draw the text
    x := menu.left;
    y_top := menu.top;
    for menu.items {
        y_bottom := y_top - h;
        defer y_top = y_bottom;

        hover := false;
        if has_focus(menu) && (mouse.y >= y_bottom && mouse.y < y_top) {
            hover = true;
            menu.hovered_item = xx it_index;
            if click {
                popup_menu_handle_click(menu);
                handled = true;
            } else if menu.callback {
                menu.callback(menu, .HOVER);
            }
        }

        #if do_draw {
            if hover {
                draw_axis_aligned_rectangle(xx X, xx y_bottom, xx W, xx h, popup_menu_hovered_item_bg_color);
            }

            draw_icon(x + h / 2.0, y_bottom + h / 2.0, it.icon);

            Simp.draw_text(font.regular, xx x + text_x_tweak, xx y_bottom + text_y_tweak, it.text, popup_menu_item_text_color);
        }
    }

    return handled;
}

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

do_simple_button :: (x: float, y: float, w: float, h: float, border: float, icon: Icon_Info, bg_color: Vector4, handle_click: bool) -> handled_click: bool {
    pad := border;

    fg_color_ := icon.color;
    bg_color_ := bg_color;

    click_handled := false;

    if handle_click && axis_aligned_rectangle_contains(x, y, w, h, mouse) {
        Swap(*fg_color_, *bg_color_);

        if is_click(.MOUSE_BUTTON_LEFT) {
            click_handled = true;
        }
    }

    draw_axis_aligned_rectangle(x, y, w, h, bg_color_);
    draw_hollow_axis_aligned_rectangle(x, y, w, h, border, text_search_ui_border_color);

    icon_ := icon;
    icon_.color = fg_color_;
    draw_icon(x + w / 2.0, y + h / 2.0, icon_);

    return click_handled;
}

draw_icon :: (x: float, y: float, icon: Icon_Info) {
    middle := Vector2.{x, y};
    if #complete icon.type == {
        case .NONE; return;
        case .SQUARE;
            w := icon.size;
            draw_axis_aligned_rectangle(x - w / 2.0, y - w / 2.0, w, w, icon.color);
        case .TRIANGLE_LEFT;
            size := icon.size;
            p0 := middle + .{-size * .4,          0};
            p1 := middle + .{ size * .4,  size * .5};
            p2 := middle + .{ size * .4, -size * .5};
            draw_triangle(p0, p1, p2, icon.color);

        case .TRIANGLE_RIGHT;
            size := icon.size;
            p0 := middle + .{ size * .4,          0};
            p1 := middle + .{-size * .4,  size * .5};
            p2 := middle + .{-size * .4, -size * .5};
            draw_triangle(p0, p1, p2, icon.color);

        case .TRIANGLE_UP;
            size := icon.size;
            p0 := middle + .{         0,  size * .4};
            p1 := middle + .{ size * .5, -size * .4};
            p2 := middle + .{-size * .5, -size * .4};
            draw_triangle(p0, p1, p2, icon.color);

        case .TRIANGLE_DOWN;
            size := icon.size;
            p0 := middle + .{         0, -size * .4};
            p1 := middle + .{ size * .5,  size * .4};
            p2 := middle + .{-size * .5,  size * .4};
            draw_triangle(p0, p1, p2, icon.color);

    }
}

Text_Input_State :: struct {
    buffer: [..] u8;
    cursor: int;

    max_length: int = -1;
    // TODO: scroll
}

Text_Input_Status :: enum_flags {
    HANDLED;
    TEXT_CHANGED;
    ENTER_HIT;
    SHIFT_PRESSED;
    CLOSED;
}

text_input_handle_event :: (state: *Text_Input_State, event: Input.Event) -> result: Text_Input_Status {
    if !event.key_pressed return 0;
    if event.alt_pressed return 0;

    if !event.ctrl_pressed && event.key_code >= #char " " && event.key_code <= #char "~" {

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

        if state.buffer.count + 1 > state.max_length {
            // TODO: error reporting
            log_error("text input truncated to % (wanted to add %)", state.max_length, 1);
            return .HANDLED;
        }

        array_insert_at(*state.buffer, char, state.cursor);
        state.cursor += 1;

        return .TEXT_CHANGED;

    } else if event.key_code == {
        case .ESCAPE;
            return .CLOSED;

        case .BACKSPACE;
            if state.cursor > 0 {
                array_ordered_remove_range(*state.buffer, state.cursor - 1, state.cursor);
                state.cursor -= 1;

                return .TEXT_CHANGED;
            }
            return .HANDLED;

        case .DELETE;
            if state.buffer.count > 0 && state.cursor < state.buffer.count {
                array_ordered_remove_range(*state.buffer, state.cursor, state.cursor + 1);

                return .TEXT_CHANGED;
            }
            return .HANDLED;

        case .ARROW_LEFT;
            if state.cursor > 0 then state.cursor -= 1;
            return .HANDLED;

        case .ARROW_RIGHT;
            if state.cursor < state.buffer.count then state.cursor += 1;
            return .HANDLED;

        case .ARROW_UP; // TODO: history
        case .ARROW_DOWN; // TODO: history

        case .HOME;
            state.cursor = 0;
            return .HANDLED;

        case .END;
            state.cursor = state.buffer.count;
            return .HANDLED;

        case xx #char "V";
            if event.ctrl_pressed {
                text := os_clipboard_get_text(,, temp);
                if text {
                    // XXX ugly and stupid
                    text = replace(text, "\r\n", "",, temp);
                    text = replace(text, "\r", "",, temp);
                    text = replace(text, "\n", "",, temp);

                    if state.buffer.count + text.count > state.max_length {
                        // TODO: error reporting
                        log_error("text input truncated to % (wanted to add %)", state.max_length, text.count);
                        return .HANDLED;
                    }

                    array_insert_at(*state.buffer, cast([] u8) text, state.cursor);
                    state.cursor += text.count;
                    return .TEXT_CHANGED;
                }
                return .HANDLED;
            }

        case .ENTER;
            if event.shift_pressed
                return .ENTER_HIT | .SHIFT_PRESSED;

            return .ENTER_HIT;
    }

    return 0;
}

draw_text_input :: (state: *Text_Input_State, x: float, y: float, w: float, font: *Simp.Dynamic_Font, fg_color: Vector4, handle_click: bool) -> click_handled: bool {
    // @INCOMPLETE TODO:
    // - scrolling
    // - mouse handling

    Simp.draw_text(font, xx x, xx y, xx state.buffer, text_search_ui_text_color);

    assert(font.temporary_glyphs.count == state.buffer.count);
    cursor_x := x;
    for font.temporary_glyphs {
        if it_index >= state.cursor break;
        cursor_x += it.advance;
    }

    {
        cursor_y_tweak := -2.0;
        cursor_y := y + cursor_y_tweak;
        w := 2;
        h := (font.character_height - font.typical_descender);

        draw_axis_aligned_rectangle(cursor_x, cursor_y, xx w, xx h, fg_color);
    }

    return false;
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

triangle_contains :: inline (t: [3] Vector2, target: Vector2) -> bool {
    return triangle_contains(t[0], t[1], t[2], target);
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
// command line arguments
//

input_file_full_path: string;
input_from_clipboard: bool;
run_tests_mode: bool;

parse_command_line_arguments :: () {
    args := get_command_line_arguments();
    log("command line arguments: %", args);

    working_directory := get_working_directory();
    working_directory_path := parse_path(working_directory);

    cursor := 1;
    while cursor < args.count {
        arg := args[cursor];

        if arg == {
            case "-clipboard";
                input_from_clipboard = true;
                cursor += 1;
                continue;
            case "-run-tests";
                run_tests_mode = true;
                cursor += 1;
                continue;
        }

        if arg[0] == #char "-" {
            log_error("unexpected option '%'", arg);
            exit(1);
        }

        break;
    }

    if cursor < args.count {
        file := args[cursor];
        if is_absolute_path(file) {
            input_file_full_path = file;
        } else if OS == .WINDOWS && file && file[0] == #char "/" {
            input_file_full_path = convert_wsl_path_to_windows(file);
        } else {
            input_file_full_path = sprint("%/%", working_directory, file);
        }
        cursor += 1;
    }

    if cursor != args.count {
        while cursor < args.count {
            arg := args[cursor];
            log_error("unexpected argument '%'", arg);
            cursor += 1;
        }
        exit(1);
    }

}

convert_wsl_path_to_windows :: (path: string) -> string {
    builder: String_Builder;
    builder.allocator = temp;

    tail := path;
    PREFIX :: "/mnt/";
    if starts_with(tail, PREFIX) && tail.count > PREFIX.count {
        append(*builder, to_upper(tail[PREFIX.count]));
        append(*builder, #char ":");

        tail = advance(tail, PREFIX.count + 1);
    }

    while tail {
        found:, head:, tail = split_from_left(tail, #char "/");
        append(*builder, head);
        if found then append(*builder, #char "\\");
    }

    return builder_to_string(*builder);
}


//
// ansi escape sequences
//

escape_code_stats: Table(string, int);
escape_code_stats_pool: Pool;
escape_code_stats_allocator: Allocator;
parse_ansi_escape_codes :: (line: string, line_start: s32, infos: *[..] Escape_Code_Info) {
    tail := line;
    offset := 0;
    while tail {
        head:, found_escape:, tail = eat_visible_or_escape_sequence(tail);
        defer offset += head.count;

        if found_escape {
            sequence := parse_escape_sequence(head);
            start := cast(s32, line_start + offset);
            array_add(infos, Escape_Code_Info.{start, xx head.count, sequence});

            count := table_find_pointer(*escape_code_stats, head);
            if count then count.* += 1;
            else {
                table_add(*escape_code_stats, copy_string(head,, escape_code_stats_allocator), 1);
            }
        }
    }
}

// @INCOMPLETE lacking unicode support
eat_visible_or_escape_sequence :: (text: string) -> head: string, found_escape: bool, tail: string {
    if !text return "", false, "";

    count := find_index_from_left(text, #char "\e");
    if count < 0 then count = text.count;

    if count > 0 {
        // Visible character sequence
        head, tail := inline split_at(text, count);

        return head, false, tail;
    }

    // Escape sequence
    count += 1;

    if count < text.count {
        char := text[count];
        if char == #char "[" {
            count += 1;
            while count < text.count {
                char = text[count];
                count += 1;

                if char >= #char "a" && char <= #char "z" break;
                if char >= #char "A" && char <= #char "Z" break;
            }
        } else {
            // TODO: don't care about other escape codes for now
        }
    }

    head, tail := inline split_at(text, count);
    return head, true, tail;
}

Small_Escape_Sequence :: struct {
    command_letter: u8;
    argument_count: u8;
    arguments: [6] u8;
}
#assert size_of(Small_Escape_Sequence) == 8;

Ansi_Style_Command :: enum {
    RESET_ALL :: 0;

    BOLD_ON           :: 1;
    FAINT_ON          :: 2;
    ITALIC_ON         :: 3;
    UNDERLINE_ON      :: 4;
    BLINKING_ON       :: 5;
    INVERSE_ON        :: 7;
    HIDDEN_ON         :: 8;
    STRIKETHROUGH_ON  :: 9;

    BOLD_FAINT_OFF    :: 22;
    ITALIC_OFF        :: 23;
    UNDERLINE_OFF     :: 24;
    BLINKING_OFF      :: 25;
    INVERSE_OFF       :: 27;
    HIDDEN_OFF        :: 28;
    STRIKETHROUGH_OFF :: 29;

    FG_BLACK   :: 30;
    FG_RED     :: 31;
    FG_GREEN   :: 32;
    FG_YELLOW  :: 33;
    FG_BLUE    :: 34;
    FG_MAGENTA :: 35;
    FG_CYAN    :: 36;
    FG_WHITE   :: 37;

    FG_COLOR   :: 38;

    FG_DEFAULT :: 39;

    BG_BLACK   :: 40;
    BG_RED     :: 41;
    BG_GREEN   :: 42;
    BG_YELLOW  :: 43;
    BG_BLUE    :: 44;
    BG_MAGENTA :: 45;
    BG_CYAN    :: 46;
    BG_WHITE   :: 47;

    BG_COLOR   :: 48;

    BG_DEFAULT :: 49;

    FG_BRIGHT_BLACK   :: 90;
    FG_BRIGHT_RED     :: 91;
    FG_BRIGHT_GREEN   :: 92;
    FG_BRIGHT_YELLOW  :: 93;
    FG_BRIGHT_BLUE    :: 94;
    FG_BRIGHT_MAGENTA :: 95;
    FG_BRIGHT_CYAN    :: 96;
    FG_BRIGHT_WHITE   :: 97;

    BG_BRIGHT_BLACK   :: 100;
    BG_BRIGHT_RED     :: 101;
    BG_BRIGHT_GREEN   :: 102;
    BG_BRIGHT_YELLOW  :: 103;
    BG_BRIGHT_BLUE    :: 104;
    BG_BRIGHT_MAGENTA :: 105;
    BG_BRIGHT_CYAN    :: 106;
    BG_BRIGHT_WHITE   :: 107;
}

Style :: struct {
    fg_color: Vector4;
    bg_color: Vector4;
    attributes: Style_Attributes;
}

Style_Attributes :: enum_flags { BOLD; FAINT; ITALIC; UNDERLINE; BLINKING; INVERSE; HIDDEN; STRIKETHROUGH; };

print :: (builder: *String_Builder, sequence: Small_Escape_Sequence) {
    append(builder, sequence.command_letter);
    append(builder, "(");
    count := cast(int) sequence.argument_count;
    for 0..count - 2
        print(builder, "%, ", cast(Ansi_Style_Command) sequence.arguments[it]);
    if sequence.argument_count
        print(builder, "%", cast(Ansi_Style_Command) sequence.arguments[sequence.argument_count - 1]);
    append(builder, ")");
}

evaluate_style_sequence :: (using sequence: Small_Escape_Sequence, using style: *Style, fg_default := Vector4.{}, bg_default := Vector4.{}) {
    if command_letter != #char "m" return;

    i := 0;
    while i < argument_count {
        command := cast(Ansi_Style_Command) arguments[i];
        if command == {
            case .RESET_ALL;
                fg_color = fg_default;
                bg_color = bg_default;
                attributes = xx 0;
            case .BOLD_ON;          attributes |= .BOLD;
            case .FAINT_ON;         attributes |= .FAINT;
            case .ITALIC_ON;        attributes |= .ITALIC;
            case .UNDERLINE_ON;     attributes |= .UNDERLINE;
            case .BLINKING_ON;      attributes |= .BLINKING;
            case .INVERSE_ON;       attributes |= .INVERSE;
            case .HIDDEN_ON;        attributes |= .HIDDEN;
            case .STRIKETHROUGH_ON; attributes |= .STRIKETHROUGH;

            case .BOLD_FAINT_OFF;    attributes &= ~(.BOLD | .FAINT);
            case .ITALIC_OFF;        attributes &= ~.ITALIC;
            case .UNDERLINE_OFF;     attributes &= ~.UNDERLINE;
            case .BLINKING_OFF;      attributes &= ~.BLINKING;
            case .INVERSE_OFF;       attributes &= ~.INVERSE;
            case .HIDDEN_OFF;        attributes &= ~.HIDDEN;
            case .STRIKETHROUGH_OFF; attributes &= ~.STRIKETHROUGH;

            case .FG_BLACK;   fg_color = color_black;
            case .FG_RED;     fg_color = color_red;
            case .FG_GREEN;   fg_color = color_green;
            case .FG_YELLOW;  fg_color = color_yellow;
            case .FG_BLUE;    fg_color = color_blue;
            case .FG_MAGENTA; fg_color = color_magenta;
            case .FG_CYAN;    fg_color = color_cyan;
            case .FG_WHITE;   fg_color = color_white;
            case .FG_COLOR;   log_error("command 38 not implemented yet"); return;
                // TODO
                // - 2;{id}
                // - 5;{r};{g};{b}
            case .FG_DEFAULT; fg_color = fg_default;

            case .BG_BLACK;   bg_color = color_black;
            case .BG_RED;     bg_color = color_red;
            case .BG_GREEN;   bg_color = color_green;
            case .BG_YELLOW;  bg_color = color_yellow;
            case .BG_BLUE;    bg_color = color_blue;
            case .BG_MAGENTA; bg_color = color_magenta;
            case .BG_CYAN;    bg_color = color_cyan;
            case .BG_WHITE;   bg_color = color_white;
            case .BG_COLOR;   log_error_once("command 48 not implemented yet"); return;
                // TODO
                // - 2;{id}
                // - 5;{r};{g};{b}
            case .BG_DEFAULT; bg_color = fg_default;

            case .FG_BRIGHT_BLACK;   fg_color = color_gray;
            case .FG_BRIGHT_RED;     fg_color = color_red;     log_error_once("bright colors not supported yet");
            case .FG_BRIGHT_GREEN;   fg_color = color_green;   log_error_once("bright colors not supported yet");
            case .FG_BRIGHT_YELLOW;  fg_color = color_yellow;  log_error_once("bright colors not supported yet");
            case .FG_BRIGHT_BLUE;    fg_color = color_blue;    log_error_once("bright colors not supported yet");
            case .FG_BRIGHT_MAGENTA; fg_color = color_magenta; log_error_once("bright colors not supported yet");
            case .FG_BRIGHT_CYAN;    fg_color = color_cyan;    log_error_once("bright colors not supported yet");
            case .FG_BRIGHT_WHITE;   fg_color = color_white;   log_error_once("bright colors not supported yet");

            case .BG_BRIGHT_BLACK;   bg_color = color_gray;
            case .BG_BRIGHT_RED;     bg_color = color_red;     log_error_once("bright colors not supported yet");
            case .BG_BRIGHT_GREEN;   bg_color = color_green;   log_error_once("bright colors not supported yet");
            case .BG_BRIGHT_YELLOW;  bg_color = color_yellow;  log_error_once("bright colors not supported yet");
            case .BG_BRIGHT_BLUE;    bg_color = color_blue;    log_error_once("bright colors not supported yet");
            case .BG_BRIGHT_MAGENTA; bg_color = color_magenta; log_error_once("bright colors not supported yet");
            case .BG_BRIGHT_CYAN;    bg_color = color_cyan;    log_error_once("bright colors not supported yet");
            case .BG_BRIGHT_WHITE;   bg_color = color_white;   log_error_once("bright colors not supported yet");
            case; log_error("unknown command: %", command);
        }
        i += 1;
    }
}

source_code_location_equals :: (a: Source_Code_Location, b: Source_Code_Location) -> bool {
    return a.line_number == b.line_number && a.character_number == b.character_number &&
        a.fully_pathed_filename == b.fully_pathed_filename;
}
source_code_location_hash :: (loc: Source_Code_Location) -> u32 {
    h := Hash.get_hash(loc.fully_pathed_filename);
    h = Hash.get_hash(loc.line_number, h);
    h = Hash.get_hash(loc.character_number, h);
    return h;
}

log_error_once_seen_locations: Table(Source_Code_Location, bool, given_hash_function=source_code_location_hash, given_compare_function=source_code_location_equals);
log_error_once :: (format_string: string, args: .. Any, loc := #caller_location, flags := Log_Flags.NONE, user_flags : u32 = 0, section : *Log_Section = null) {
    seen, ok := table_find(*log_error_once_seen_locations, loc);
    if ok && seen return;

    table_add(*log_error_once_seen_locations, loc, true);
    inline log_error(format_string, ..args, loc=loc, flags=flags, user_flags=user_flags, section=section);
}

parse_escape_sequence :: (s: string) -> Small_Escape_Sequence, bool {
    if s.count < 3 return .{}, false;
    if s[0] != #char "\e" return .{}, false;
    if s[1] != #char "[" return .{}, false;

    result: Small_Escape_Sequence;
    cursor := 2;
    parsing_number := false;
    while cursor < s.count {
        c := s[cursor];
        if inline is_alpha(c) {
            if parsing_number then result.argument_count += 1;
            result.command_letter = c;
            break;
        } else if inline is_digit(c) {
            arg := *result.arguments[result.argument_count];
            arg.* = arg.* * 10 + c - #char "0";
            parsing_number = true;
        } else if c == #char ";" {
            if parsing_number {
                result.argument_count += 1;
                parsing_number = false;
            }
        }
        cursor += 1;
    }

    assert(result.command_letter != 0);
    return result, true;
}

//
// logging
//

my_logger :: (message: string, data: *void, info: Log_Info) {
    builder: String_Builder;
    builder.allocator = temp;

    if info.common_flags & .ERROR   print(*builder, "\e[31m");
    if info.common_flags & .WARNING print(*builder, "\e[33m");

    print_time_for_log(*builder, to_calendar(current_time_consensus(), .LOCAL));
    print(*builder, ": ");
    if #compile_time print(*builder, "#compile_time ");

    filename := path_filename(info.location.fully_pathed_filename);
    print(*builder, "[%:%] %\n", filename, info.location.line_number, message);

    if info.common_flags & (.ERROR | .WARNING) print(*builder, "\e[0m");

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
        return printer(builder, any);
    }

    if any.type == type_info(Source_Code_Location) {
        print_source_code_location(builder, xx any.value_pointer);
        return true;
    } else if any.type == type_info(Ascii_Or_Hex) {
        print_ascii_or_hex(builder, xx cast(*Ascii_Or_Hex, any.value_pointer).*);
        return true;
    } else if any.type == type_info(Small_Escape_Sequence) {
        print(builder, cast(*Small_Escape_Sequence, any.value_pointer).*);
        return true;
    }

    return false;
}

Struct_Printer_Type :: #type (*String_Builder, Any) -> bool;

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

Ascii_Or_Hex :: #type,distinct string;

print_ascii_or_hex :: (builder: *String_Builder, s: string) {
    for 0..s.count-1 {
        char := s[it];
        if char >= #char " " && char <= #char "~" {
            if char == #char "\\" || char == #char "\""
                append(builder, "\\");
            append(builder, char);
        } else {
            print_to_builder(builder, "\\x%", FormatInt.{ value = char, base = 16, minimum_digits = 2 });
        }
    }
}

//
// miscellaneous
//

Parse_Date_Time_Result :: enum_flags {
    DATE; TIME; MILLISECONDS;
    FULL :: DATE | TIME | MILLISECONDS;
}
parse_date_time_stamp :: (input: string) -> (Calendar_Time, Parse_Date_Time_Result, tail: string) {
    _0 :: #char "0";

    result: Calendar_Time;
    // Won't be able to parse this
    result.day_of_week_starting_at_0 = -1;
    tail := input;

    status: Parse_Date_Time_Result;
    // Calendar_Time :: struct {
    //     year:        s32;
    //     month_starting_at_0: s8;         // 0-11. Use as an index to a month name array, or add 1 to get the normal human-readable number.
    //     day_of_month_starting_at_0: s8;  // 0-30. Add 1 to get the normal human-readable number.
    //     day_of_week_starting_at_0: s8;   // Sunday, Monday, Tuesday, Wednesday, Thursday, Friday, Saturday.
    //     hour:        s8;
    //     minute:      s8;
    //     second:      s8;
    //     millisecond: s16;
    //     time_zone: Time_Zone;
    // }

    cursor := 0;

    // skip whitespace
    while cursor < input.count && inline is_space(input[cursor]) { cursor += 1; }
    tail = advance(input, cursor);
    if cursor >= input.count return result, status, tail;

    //
    // parse date `YYYY.MM.DD` (any separator)
    //
    if input.count - cursor < 10 return result, status, tail;

    // year
    {
        y0 := input[cursor]; cursor += 1;
        y1 := input[cursor]; cursor += 1;
        y2 := input[cursor]; cursor += 1;
        y3 := input[cursor]; cursor += 1;
        if !(inline is_digit(y0)) || !(inline is_digit(y1)) || !(inline is_digit(y2)) || !(inline is_digit(y3)) {
            return result, status, tail;
        }
        result.year = xx (cast(s32, y0 - _0) * 1000 + cast(s32, y1 - _0) * 100 + cast(s32, y2 - _0) * 10 + cast(s32, y3 - _0));
    }

    // separator
    sep := input[cursor]; cursor += 1;
    if (inline is_digit(sep)) || (inline is_alpha(sep)) return result, status, tail;

    // month
    {
        m0 := xx input[cursor]; cursor += 1;
        m1 := xx input[cursor]; cursor += 1;
        if !(inline is_digit(m0)) || !(inline is_digit(m1)) return result, status, tail;
        result.month_starting_at_0 = xx ((m0 - _0) * 10 + (m1 - _0) - 1);
    }

    // separator
    sep = input[cursor]; cursor += 1;
    if (inline is_digit(sep)) || (inline is_alpha(sep)) return result, status, tail;

    // day
    {
        d0 := xx input[cursor]; cursor += 1;
        d1 := xx input[cursor]; cursor += 1;
        if !(inline is_digit(d0)) || !(inline is_digit(d1)) return result, status, tail;
        result.day_of_month_starting_at_0 = xx ((d0 - _0) * 10 + (d1 - _0) - 1);
    }

    status = .DATE;
    tail = advance(input, cursor);
    if cursor >= input.count return result, status, tail;

    // separator
    sep = input[cursor]; cursor += 1;
    if (inline is_digit(sep)) || (inline is_alpha(sep)) return result, status, tail;

    // skip whitespace
    while cursor < input.count && inline is_space(input[cursor]) { cursor += 1; }
    tail = advance(input, cursor);
    if cursor >= input.count return result, status, tail;

    //
    // parse time `HH:MM:SS` (any separator)
    //
    if input.count - cursor < 8 return result, status, tail;

    // hour
    {
        h0 := xx input[cursor]; cursor += 1;
        h1 := xx input[cursor]; cursor += 1;
        if !(inline is_digit(h0)) || !(inline is_digit(h1)) return result, status, tail;
        result.hour = xx ((h0 - _0) * 10 + (h1 - _0));
    }

    // separator
    sep = input[cursor]; cursor += 1;
    if (inline is_digit(sep)) || (inline is_alpha(sep)) return result, status, tail;

    // minute
    {
        m0 := input[cursor]; cursor += 1;
        m1 := input[cursor]; cursor += 1;
        if !(inline is_digit(m0)) || !(inline is_digit(m1)) return result, status, tail;
        result.minute = xx ((m0 - _0) * 10 + (m1 - _0));
    }

    // separator
    sep = input[cursor]; cursor += 1;
    if (inline is_digit(sep)) || (inline is_alpha(sep)) return result, status, tail;

    // second
    {
        s0 := input[cursor]; cursor += 1;
        s1 := input[cursor]; cursor += 1;
        if !(inline is_digit(s0)) || !(inline is_digit(s1)) return result, status, tail;
        result.second = xx ((s0 - _0) * 10 + (s1 - _0));
    }

    status |= .TIME;
    tail = advance(input, cursor);

    //
    // parse millisecond `.MMM` (any separator)
    //
    if input.count - cursor < 4 return result, status, tail;

    // separator
    sep = input[cursor]; cursor += 1;
    if (inline is_digit(sep)) || (inline is_alpha(sep)) return result, status, tail;

    // millisecond
    {
        m0 := input[cursor]; cursor += 1;
        m1 := input[cursor]; cursor += 1;
        m2 := input[cursor]; cursor += 1;
        if !(inline is_digit(m0)) || !(inline is_digit(m1)) || !(inline is_digit(m2)) return result, status, tail;
        result.millisecond = xx (cast(s16, m0 - _0) * 100 + cast(s16, m1 - _0) * 10 + cast(s16, m2 - _0));
    }

    status |= .MILLISECONDS;
    tail = advance(input, cursor);

    return result, status, tail;
}

test_parse_date_time_stamp :: () {
    line: string;

    {
        line = "2025:02:26 17:05:33.047 tail";
        date_time, status, tail := parse_date_time_stamp(line);
        assert(status == .FULL);
        assert(date_time.year == 2025);
        assert(date_time.month_starting_at_0 == 1);
        assert(date_time.day_of_month_starting_at_0 == 25);
        assert(date_time.day_of_week_starting_at_0 == -1);
        assert(date_time.hour == 17);
        assert(date_time.minute == 5);
        assert(date_time.second == 33);
        assert(date_time.millisecond == 47);
        assert(tail == " tail");
    }

    {
        line = "  2003:03:13 no time?";
        date_time, status, tail := parse_date_time_stamp(line);
        assert(status == .DATE);
        assert(date_time.year == 2003);
        assert(date_time.month_starting_at_0 == 2);
        assert(date_time.day_of_month_starting_at_0 == 12);
        assert(date_time.day_of_week_starting_at_0 == -1);
        assert(date_time.hour == 0);
        assert(date_time.minute == 0);
        assert(date_time.second == 0);
        assert(date_time.millisecond == 0);
        assert(tail == "no time?");
    }

    {
        line = "1993:05:19 12:30:00 not accurate enough!";
        date_time, status, tail := parse_date_time_stamp(line);
        assert(status == .DATE | .TIME);
        assert(date_time.year == 1993);
        assert(date_time.month_starting_at_0 == 4);
        assert(date_time.day_of_month_starting_at_0 == 18);
        assert(date_time.day_of_week_starting_at_0 == -1);
        assert(date_time.hour == 12);
        assert(date_time.minute == 30);
        assert(date_time.second == 0);
        assert(date_time.millisecond == 0);
        assert(tail == " not accurate enough!");
    }

    {
        line = "  garbage!";
        date_time, status, tail := parse_date_time_stamp(line);
        assert(status == 0);
        assert(date_time.year == 0);
        assert(date_time.month_starting_at_0 == 0);
        assert(date_time.day_of_month_starting_at_0 == 0);
        assert(date_time.day_of_week_starting_at_0 == -1);
        assert(date_time.hour == 0);
        assert(date_time.minute == 0);
        assert(date_time.second == 0);
        assert(date_time.millisecond == 0);
        assert(tail == "garbage!");
    }

    {
        line = "";
        date_time, status, tail := parse_date_time_stamp(line);
        assert(status == 0);
        assert(date_time.year == 0);
        assert(date_time.month_starting_at_0 == 0);
        assert(date_time.day_of_month_starting_at_0 == 0);
        assert(date_time.day_of_week_starting_at_0 == -1);
        assert(date_time.hour == 0);
        assert(date_time.minute == 0);
        assert(date_time.second == 0);
        assert(date_time.millisecond == 0);
        assert(tail == "");
    }

    {
        line = "   \t  \n  \r ";
        date_time, status, tail := parse_date_time_stamp(line);
        assert(status == 0);
        assert(date_time.year == 0);
        assert(date_time.month_starting_at_0 == 0);
        assert(date_time.day_of_month_starting_at_0 == 0);
        assert(date_time.day_of_week_starting_at_0 == -1);
        assert(date_time.hour == 0);
        assert(date_time.minute == 0);
        assert(date_time.second == 0);
        assert(date_time.millisecond == 0);
        assert(tail == "");
    }
}

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

resizable_array :: (items: [] $T) -> [..] T {
    result: [..] T;
    result.allocator = context.allocator;
    array_add(*result, .. items);
    return result;
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

array_insert_at :: (array: *[..] $T, items: [] T, index: int) {
    assert(index >= 0);
    assert(index <= array.count);
    if !items.count return;

    maybe_grow(xx array, items.count * size_of(T));

    array.count += items.count;

    i := array.count-1;
    while i > index + items.count - 1 {
        array.data[i] = array.data[i-items.count];
        i -= 1;
    }

    memcpy(array.data + index, items.data, items.count * size_of(T));
}

// Stole this from modules/Sort. Minor changes.
// @Speed: This version of quick_sort (and probably the other one)
// seems to compare items to themselves a lot, which is clearly pointless.
// Fix that!
quick_sort :: inline (array: [] $T, $f: (T, T) -> $R) -> [] T {  // R is an integer type, but may be e.g. 32-bit.
    quicksort_helper :: (a: *T, n: s64) {
        if n < 2 return;

        p := a[n / 2];

        i := 0;
        j := n-1;

        while true {
            while f(a[i], p) < 0  {i += 1;}
            while f(p, a[j]) < 0  {j -= 1;}

            if i >= j break;

            t := a[i];
            a[i] = a[j];
            a[j] = t;

            i += 1;
            j -= 1;
        }

        quicksort_helper(a, i);
        quicksort_helper(a + i, n - i);
    }

    quicksort_helper(array.data, array.count);
    return array;
}

test_quick_sort :: () {
    array := int.[6, 1, 3, 5, 2, 4, 7, 0];
    quick_sort(array, (l, r) => l - r);
    assert(array_equals(array, .[0, 1, 2, 3, 4, 5, 6, 7]));

    array = int.[6, 1, 3, 5, 2, 4, 7, 0];
    quick_sort(array, (l, r) => r - l);
    assert(array_equals(array, .[7, 6, 5, 4, 3, 2, 1, 0]));
}

test_array_insert_at :: () {
    array: [..] int;

    array = resizable_array(int.[1, 2, 3, 4, 5, 6],, temp);
    for 0..array.count {
        array_insert_at(*array, .[], it);
        assert(array_equals(array, .[1, 2, 3, 4, 5, 6]), "it: %, %", it, array);
    }

    array = resizable_array(int.[1, 2, 3, 4, 5, 6],, temp);
    array_insert_at(*array, .[0xa, 0xb, 0xc], 0);
    assert(array_equals(array, .[0xa, 0xb, 0xc, 1, 2, 3, 4, 5, 6]), "%", array);

    array = resizable_array(int.[1, 2, 3, 4, 5, 6],, temp);
    array_insert_at(*array, .[0xa, 0xb, 0xc], 1);
    assert(array_equals(array, .[1, 0xa, 0xb, 0xc, 2, 3, 4, 5, 6]), "%", array);

    array = resizable_array(int.[1, 2, 3, 4, 5, 6],, temp);
    array_insert_at(*array, .[0xa, 0xb, 0xc], 2);
    assert(array_equals(array, .[1, 2, 0xa, 0xb, 0xc, 3, 4, 5, 6]), "%", array);

    array = resizable_array(int.[1, 2, 3, 4, 5, 6],, temp);
    array_insert_at(*array, .[0xa, 0xb, 0xc], 3);
    assert(array_equals(array, .[1, 2, 3, 0xa, 0xb, 0xc, 4, 5, 6]), "%", array);

    array = resizable_array(int.[1, 2, 3, 4, 5, 6],, temp);
    array_insert_at(*array, .[0xa, 0xb, 0xc], 4);
    assert(array_equals(array, .[1, 2, 3, 4, 0xa, 0xb, 0xc, 5, 6]), "%", array);

    array = resizable_array(int.[1, 2, 3, 4, 5, 6],, temp);
    array_insert_at(*array, .[0xa, 0xb, 0xc], 5);
    assert(array_equals(array, .[1, 2, 3, 4, 5, 0xa, 0xb, 0xc, 6]), "%", array);

    array = resizable_array(int.[1, 2, 3, 4, 5, 6],, temp);
    array_insert_at(*array, .[0xa, 0xb, 0xc], 6);
    assert(array_equals(array, .[1, 2, 3, 4, 5, 6, 0xa, 0xb, 0xc]), "%", array);

    // This one crashes:
    // array = resizable_array(int.[1, 2, 3, 4, 5, 6],, temp);
    // array_insert_at(*array, .[0xa, 0xb, 0xc], 7);

}

array_equals :: (a: [] $T, b: [] T) -> bool {
    if a.count != b.count return false;
    for a if it != b[it_index] return false;
    return true;
}

advance :: (array: [] u8, bytes: s64) -> result: [] u8 {
    assert(array.count >= bytes);

    result := array;
    result.data  += bytes;
    result.count -= bytes;

    return result;
}

split_at :: (a: [] $T, i: int) -> ([] T, [] T) {
    assert(i >= 0, "%", i);
    assert(i <= a.count, "%", i);

    if i == 0 return .[], a;
    if i == a.count return a, .[];

    l: [] T = ---;
    l.data = a.data;
    l.count = i;

    r: [] T = ---;
    r.data = a.data + i;
    r.count = a.count - i;

    return l, r;
}

replace_in_place :: (s: string, old: u8, new: u8) -> string {
    cursor := 0;
    while true {
        cursor = find_index_from_left(s, old, cursor);
        if cursor == -1 break;
        s[cursor] = new;
    }
    return s;
}

split_at :: (s: string, i: int) -> (string, string) {
    l, r := inline split_at(cast([] u8) s, i);
    return xx l, xx r;
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

run_tests :: () {
    t0 := seconds_since_init();
    log("running tests...");
    log("test_search_for_match");          test_search_for_match();
    log("test_array_insert_at");           test_array_insert_at();
    log("test_quick_sort");                test_quick_sort();
    log("test_parse_date_time_stamp");     test_parse_date_time_stamp();
    elapsed := seconds_since_init() - t0;
    log("\e[32mtests passed!\e[0m elapsed %", fmt(elapsed, 3));
}

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
#import "File_Utilities";
#import "Clipboard";
#import "Pool";
Hash :: #import "Hash";
