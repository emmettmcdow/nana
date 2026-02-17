test "debug view embedding splitting" {
    if (true) return error.SkipZigTest; // Skipping as this is not something we need always
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();

    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, te.iface);
    defer db.deinit();

    std.debug.print("--- Embedding Split ---\n", .{});
    var it = db.embedder.split(EXAMPLE_NOTE_1);
    var n: f32 = 0;
    var n_split: f32 = 0;
    while (it.next()) |chunk| {
        var embedded = chunk.contents.len > 2;
        const embedding = try db.embedder.embed(arena.allocator(), chunk.contents);
        embedded = embedded and (embedding != null);
        n_split += if (embedded) 1.0 else 0.0;
        n += 1.0;
        std.debug.print("({}, {s})\n", .{ embedded, chunk.contents });
    }
    const percentage = (n_split / n) * 100;
    std.debug.print("{d:.2}% Embedded\n", .{percentage});
    std.debug.print("-----------------------\n\n", .{});
}

test "debug search example 2" {
    if (true) return error.SkipZigTest; // Skipping as this is not something we need always
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, te.iface);
    defer db.deinit();

    try db.embedText("test_path", EXAMPLE_NOTE_2);

    var buf: [100]SearchResult = undefined;
    const n = try db.search("china", &buf);
    for (buf[0..n]) |res| {
        const snippet = EXAMPLE_NOTE_2[res.start_i..res.end_i];
        std.debug.print(
            "path: {s}, start_i: {d}, end_i: {d}, similarity: {d:.4}\n  snippet: \"{s}\"\n",
            .{ res.path, res.start_i, res.end_i, res.similarity, snippet },
        );
    }
}

test "debug search example 3" {
    if (true) return error.SkipZigTest; // Skipping as this is not something we need always
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, te.iface);
    defer db.deinit();

    try db.embedText("test_path", EXAMPLE_NOTE_3);

    var buf: [100]SearchResult = undefined;
    const n = try db.search("china", &buf);
    for (buf[0..n]) |res| {
        const snippet = EXAMPLE_NOTE_3[res.start_i..res.end_i];
        std.debug.print(
            "path: {s}, start_i: {d}, end_i: {d}, similarity: {d:.4}\n  snippet: \"{s}\"\n",
            .{ res.path, res.start_i, res.end_i, res.similarity, snippet },
        );
    }
}

const Embedder = switch (embedding_model) {
    .apple_nlembedding => embed.NLEmbedder,
    .mpnet_embedding => embed.MpnetEmbedder,
};

fn testEmbedder(allocator: std.mem.Allocator) !struct { e: *Embedder, iface: embed.Embedder } {
    const e = try allocator.create(Embedder);
    e.* = try Embedder.init();
    return .{ .e = e, .iface = e.embedder() };
}

const std = @import("std");
const testing_allocator = std.testing.allocator;

const config = @import("config");
const embed = @import("embed.zig");
const vector = @import("vector.zig");
const SearchResult = vector.SearchResult;
const embedding_model: embed.EmbeddingModel = @enumFromInt(@intFromEnum(config.embedding_model));
const TestVecDB = vector.VectorDB(embedding_model);

const EXAMPLE_NOTE_1 =
    \\Web Manager
    \\
    \\## Functionality
    \\- Generate NGINX config
    \\- Start / Stop Containers
    \\- Manage available ports
    \\- Manage volumes / Persistent storage
    \\- Update applications
    \\
    \\## Thoughts
    \\
    \\How do we want to configure the worker?
    \\It would be nice to have the ingress server be its own container. The only problem I can think of is the fact that we would need to be able to access ports which may be present only on the host.
    \\
    \\It should be possible to create a network, then have my various containers use it.
    \\
    \\I need to clear out kamal stuff on my server
    \\
    \\## Important commands
    \\```
    \\docker network create -d bridge test-network
    \\
    \\# Server
    \\docker run --network=test-network -p 8082:8082 --name=nginx-server -d nginx-test:1
    \\
    \\# Client
    \\docker run --network=test-network -it ubuntu:latest
    \\
    \\# Within the client
    \\curl nginx-server:8082
    \\```
;

const EXAMPLE_NOTE_2 =
    \\ # Address Locations
    \\ - Robins Financial
    \\ - ✅ Amex
    \\ - ✅ Capital One Silver
    \\ - ✅ Capital One Journey
    \\ - ✅ Janice Lee
    \\ - Double check work
    \\ - ✅ Apollo
    \\ - ✅ Dentist
    \\ - ✅ Car insurance
    \\ - ✅ DMV (registration)
    \\ - ✅ Drivers License(Emmett)
;

const EXAMPLE_NOTE_3 =
    \\# 2025 Year in Review
    \\2025 was my pivotal year. It was the year where my intellectual, professional, and personal aspects of my life seemed to fall into place. Even my "failures" seemed to play to my favor and inform my future decisions.
    \\
    \\## Projects
    \\### TuneTree
    \\Early this year, I finished a project called [tunetree](https://tunetree.xyz). Tunetree is basically [Linktree](https://linktr.ee) mixed with [Substack](https://substack.com). The idea behind it is that musicians should have a hub to share their music and support their work through fan subscriptions.
    \\Tunetree did not pan out quite the way I imagined, but it was an incredible learning experience. 
    \\
    \\#### Move fast, break things, move slow
    \\I wanted to experiment with writing no tests. This started as a reaction to my percieved stifling of creativity at my dayjob  due to organizational conservativism. I wanted to take the "move fast and break things" philosophy to its logical extreme. The result was predictable, over time I grew progressively more fearful of my own code. Giant bugs lurked around every corner, and the only logical way to avoid regressions was to do less. I learned it is certainly possible to write too few tests, despite what the vibecoders on X would have you believe. Unfortunately, the correct amount and type of tests depends on the context, and there's no magic formula. It's our job as engineers to weigh the cost and benefits of tests in every situation and use our (in my case, hard earned) experience to guide our intuition.
    \\
    \\#### For the love of god, stop adding features
    \\It took me forever to get my app in front of my first user. I would write a "good-enough") version of a feature, revel in my genius, add a new feature, and rinse and repeat. This had predictable consequences. The problem with doing things this way is that you get a giant ball of half-baked features that break when they aren't spoon-fed the well-formed inputs you try when you're prototyping. I always expected to have to iterate on the features. But there are second-order issues with this approach. Firstly, when you work like this, it takes a big toll on your mental ability to reason about your own codebase. I like to think my brain has a cache. When you are working on a feature, it takes time to build up a mental model of the system. Mental models are evicted from the cache if they aren't recently used. If you half-ass a feature, you're delaying completing it. When you come back to it, your mental model has been evicted from the cache and you're going to waste time repopulating up your mental cache. You're basically [thrashing your cache](https://en.wikipedia.org/wiki/Thrashing_(computer_science)). Secondly, it means it's going to take you **forever** to get an MVP out to users. This problem compounds the mistake I will speak about next.
    \\
    \\#### You actually need to market things
    \\I fell victim to the fallacy of "if you build it they will come". I have a friend who is a musician and he has many musician friends. I worked it out with him where I would have Tunetree ready for him in time for his new album release. My thinking was that when he released his album, all his friends would see his page on Tunetree and want their own page. He released his album and then I waited patiently for the new signups to roll in. I ended up getting zero new signups after that.
    \\
    \\The fact that I didn't test my code, I wrote a plethora of half-baked features, and I delayed marketing until the last possible moment meant that by the time I released and I didn't get the signups I expected, I lost all hope. I chalked the project up as a loss and moved on to my next project. 
    \\
    \\I may return to this at some point, I feel like I could probably re-write this app well with about a month of work. Who knows what the future holds. 
    \\
    \\### Discord Server Newsletter Generator
    \\#### Background
    \\Taking what I learned from Tunetree, I spent some time working on various MVPs. Around this time, I met some cool internet people. [@DefenderOfBasic](https://x.com/DefenderOfBasic) introduced me to a project created by [@exgenesis](https://x.com/exgenesis) called [The Community Archive](https://www.community-archive.org). The community archive is an archive of X which is populated by user uploads. This has two major purposes. Firstly it is to replace the free Twitter APIs which were locked behind a paywall during the transition to X. Secondly, companies like Palantir and HFT firms are already conducting research into patterns of behavior of communities __without our permission__. This aims to turn that on its head, making the project __opt in__, and facilitating research __in public__. Check it out if you care about open-source research and data-sovreignty!
    \\
    \\#### The inspiration.
    \\I joined the Community Archive discord server and had a bunch of fun [brainstorming ideas](https://github.com/TheExGenesis/community-archive/issues/207). There were a ton of active users at the time, and many people would drop links to cool stuff happening in the world of online community research. There were more links than I could usually read, and we were considering ways to do outreach to grow the community. I came up with the idea of building an app which would generate a newletter based on the links from the past week in the server.
    \\
    \\#### The design
    \\The prinicples behind this app were that I wanted to keep a human in the loop as much as possible. LLMs are still not good at filtering based on fuzzy human criteria such as "quality" or "relevance".  The app would scrape the server for all of the links posted in the past week, and then present previews to the user. The user would then delete any low quality or irrelevant links. Once the user is happy with the collection of links, they could confirm and the app would scrape the contents of each of the links. The app would then take the content of each of the links, and a prompt describing the purpose of the newsletter and feed it to Gemini. This would produce some pretty high quality newsletters!
    \\
    \\#### Results
    \\You can take a look at the project [here](https://github.com/emmettmcdow/discord-newsletter-generator). With some modification, you could probably get it working for any Discord server. It looked good, and it worked pretty well. I took my experience with TuneTree and learned from my mistakes. I only spent about a month on the whole project, and I pushed out to users as soon as I could. The other members of the server seemed quite impressed. However there wasn't much interest in a Community Archive newletter outside the server, so nothing happened with it. Regardless I'm proud of my work, and it planted the seed for my current app.
    \\
    \\### Not Another Notes App!
    \\My experience with the Community Archive exposed me to the concept of [embeddings](https://en.wikipedia.org/wiki/Embedding_(machine_learning)), and more specifically [semantic vector search](https://en.wikipedia.org/wiki/Semantic_search). Basically, words or sentences can be mapped onto a high-dimensional vector space which encodes the meaning. This can be used to compare the similarity between texts, which can also be used for search.
    \\
    \\#### My dream notes app
    \\I've always been frustrated with most search solutions(excluding Google and [kagi](https://kagi.com)). In particular searching through my personal and work notes has always been a struggle. I know generally what I want, but I can't seem to get the right keyword to locate it. I needed a "***vibe-search***".
    \\
    \\Additionally, I love using markdown. But I haven't ever been particularly impressed with the existing options. Notion requires a subscription(so I can't use it at work), and uses Electron which makes the application resource-hungry. Obsidian is nice, but I prefer opinionated design to customization, and Obsidian also uses Electron. Apple notes has been my go-to due to it's simplicity and ubiquity. But the search sucks, it has too many buttons, and it doesn't really support markdown.
    \\
    \\I wanted a notes app which:
    \\- Has "vibe-search".
    \\- Has an agressively minimalist interface(think [iPod Shuffle](https://en.wikipedia.org/wiki/IPod_Shuffle)).
    \\- Is native software(doesn't run a whole web browser for a notes app).
    \\- Doesn't require a subscription(ML/AI runs locally, it uses iCloud for storage).
    \\
    \\So I set out to build it myself. I've spent the whole year working on it. I haven't released it to anyone but myself. You may be asking yourself:
    \\> Emmett, didn't you just tell us how you're a changed man, and how you're going to release your MVPs earlier so that you don't waste your time?
    \\I did, but this is different. The reason it is important to release early is so you can get early feedback and work on __the most important stuff__, and also so you can stay motivated so that you don't abandon a ton of work. The difference is that I've been using my own notes app as my daily-driver notes app for the past year. I'm writing this blog post in it now! You don't need to worry about finding users if you always have a user(yourself). And you'll maintain your motivation to improve it because you don't want to use a bad product.
    \\
    \\#### Let me in!
    \\The notes app is not ready for prime-time quite yet. I hope to have it out to early users in the next few months. If you're interested in joining the alpha, shoot me an e-mail at `firstname dot lastname at gmail`.  It only runs on Macs for now, unfortunately. 
    \\
    \\## Roadmap for 2026
    \\Next year, I hope to:
    \\- Grow my notes app to have some users beyond my friends and family.
    \\- Make some new friends in SF! (this means **you** if you live in SF!)
    \\- Do some more writing.
    \\
    \\## Special thanks to...
    \\- My brother Aidan for encouraging me to get back into writing, I really needed that. If you are looking for a talented, curious, and motivated junior security engineer, shoot him a message on [LinkedIn](https://www.linkedin.com/in/aidan-mcdow/).
    \\- My beautiful wife Claire for supporting all of my wild hairs and supporting me every step of the way.
    \\- My friend, colleague, and now boss Justin Sampson for showing me the art of craftsmanship and how to find joy in any domain. If intellectually rigorous explorations of consciousness are your jam, check out his substack [Sampsonetics](https://sampsonetics.substack.com).
    \\- Silicon Valley veteran and all-around great guy Chuck McManis, who responded to my cold e-mail and put me on the right track.
    \\- My dear friend Davidson Poole, for learning some Mandarin so we could visit China.
    \\- My dear friend and brother of my other dear friend Abram Poole, for being my first user of TuneTree.
    \\- The talented and visionary [@DefenderOfBasic](https://x.com/DefenderOfBasic) and [@exgenesis](https://x.com/exgenesis), for building a great community and inspiring my current work!
    \\- My name twin Emmett Naughton for giving me the great idea to do a year-in-review. Check his out [here](https://emmettnaughton.com/posts/2025-what-a-year/).
;
