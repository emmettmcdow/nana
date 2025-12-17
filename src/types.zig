const config = @import("config");
pub const vec_sz = config.vec_sz;

pub const VectorID = usize;
pub const vec_type = f32;
pub const Vector = @Vector(vec_sz, vec_type);
