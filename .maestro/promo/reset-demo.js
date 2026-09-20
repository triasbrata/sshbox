// Puts shop.customers back the way db-edit.yaml found it (mongosh, db "shop").
db.customers.updateOne({ name: 'Grace Hopper' }, { $set: { city: 'Surabaya' } });
db.customers.deleteMany({ name: 'Linus Torvalds' });
printjson(db.customers.find({}, { _id: 0, name: 1, city: 1 }).toArray());
