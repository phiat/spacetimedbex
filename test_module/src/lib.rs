use spacetimedb::{table, reducer, ReducerContext, Table};

#[table(accessor = person, public)]
pub struct Person {
    #[primary_key]
    #[auto_inc]
    id: u64,
    name: String,
    age: u32,
}

#[reducer]
pub fn add_person(ctx: &ReducerContext, name: String, age: u32) {
    ctx.db.person().insert(Person { id: 0, name, age });
}

#[reducer]
pub fn say_hello(_ctx: &ReducerContext) {
    log::info!("Hello from SpacetimeDB!");
}
