const math = @import("std").math;

pub fn easeInOutQubic(t: f32) f32 {
    return if (t < 0.5) 4 * t * t * t else 1 - math.pow(f32, -2 * t + 2, 3) / 2;
}
