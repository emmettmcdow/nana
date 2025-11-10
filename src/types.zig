const config = @import("config");
pub const vec_sz = config.vec_sz;

pub const VectorID = usize;
// const vec_type = config.vec_type;
pub const vec_type = f32;
pub const Vector = @Vector(vec_sz, vec_type);
