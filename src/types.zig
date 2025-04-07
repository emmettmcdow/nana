const config = @import("config");

pub const VectorID = usize;
pub const vec_sz = config.vec_sz;
// const vec_type = config.vec_type;
pub const vec_type = f32;
pub const Vector = @Vector(vec_sz, vec_type);
