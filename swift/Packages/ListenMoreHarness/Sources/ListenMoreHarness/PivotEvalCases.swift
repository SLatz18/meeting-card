import Foundation
import ListenMoreCore

/// The self-pivot precision run's cases: synthetic, generic lines written for it (no real people, companies or
/// recordings). Each is one exchange: Them's lines (one voice or two), then You's reply. Positives are true
/// pivots (the user answers a personal share with their own story and asks nothing back, including after an
/// acknowledgment); negatives are the look-alikes the cue must never fire on, including the celebrate
/// (group-plan) and message-passing replies from the gate's reviews.
extension PivotEval {
    static let marathon = "I finally ran my first half marathon on Sunday and I was so nervous at the start line."
    static let worried = "My dad has been in the hospital all week and I have been so worried about him."
    static let engaged = "We just got engaged last weekend and I am still so excited about it."
    static let moved = "We just moved into a new apartment and I am still unpacking boxes every evening."
    static let lake = "I just got back from a week at the lake with the kids and I was so relaxed."
    static let camping = "We just got back from a camping trip and I was so tired after the long hike up the trail."
    static let workUpdate = "Sure, yesterday I finished my part of the migration and today I am on my code reviews, then I will pick up my next ticket."

    public static let positives: [Case] = [
        .reply("reminds-me", .positive, them: [marathon],
               you: "Oh nice, that reminds me of when I did a long charity bike ride last spring, I was exhausted for days and my legs were sore the whole week."),
        .reply("mostly-me", .positive, them: [marathon],
               you: "Oh nice, I did a long charity ride last spring and I was so tired, my legs were sore for a week and I slept all weekend."),
        .reply("ack-then-story", .positive, them: [worried],
               you: "I'm so sorry, that's rough. When my dad had surgery I was at the hospital every night and I barely slept for a month."),
        .reply("sorry-then-own-hospital-story", .positive, them: [worried],
               you: "I'm so sorry. My mom was in the hospital last year and I was there every night, I barely slept for a month."),
        .reply("same-here-own-dad", .positive, them: [worried],
               you: "So sorry to hear that. Same here, my dad was in for a week in the spring and I was driving there every day after work."),
        .reply("hope-then-own-surgery-story", .positive, them: [worried],
               you: "Oh no, so sorry, hope it gets better soon. My dad had the same surgery last year and I was at the hospital with my mom every night."),
        .reply("congrats-own-house", .positive, them: [moved],
               you: "Congrats! We just bought a house too and I have been painting every single weekend since we moved in, my back is killing me."),
        .reply("group-reaction-then-story", .positive, them: [marathon, "Wow, congratulations!"],
               you: "Oh nice, that reminds me of when I did a long charity bike ride last spring, I was exhausted for days and my legs were sore the whole week."),
        .reply("own-birthday-trip", .positive, them: [engaged],
               you: "I celebrate my birthday next week, we're doing a big trip to the coast and I have been planning it for months, I can't wait."),
        .reply("own-trail-story", .positive, them: [camping],
               you: "We should all go sometime, I did that trail last year and I was exhausted for days after the climb, my knees still hurt."),
        // A known gate miss: "we" counts as the user only after sympathy, so this pivot is no candidate (the
        // shadow recall counts it against the gate).
        .reply("plural-own-story-gate-miss", .positive, them: [moved],
               you: "We did the same thing last year, we drove around for months looking at places and we moved twice before it felt right."),
        .reply("own-wedding-story", .positive, them: ["I just got back from my sister's wedding and I was so emotional the whole day."],
               you: "Oh nice, that reminds me of when I went to my cousin's wedding last spring, I was so tired I slept all weekend after."),
    ]

    public static let negatives: [Case] = [
        .reply("celebrate-group-plan", .negative, them: [engaged],
               you: "Congrats! We should all go out to celebrate, I will book us a table somewhere nice for Friday night after work."),
        .reply("message-mom-says-hi", .negative, them: [marathon],
               you: "My mom says hi, she saw the photos from the race and she wanted me to tell you that she is so proud of you."),
        .reply("message-son-asked", .negative, them: [marathon],
               you: "My son asked about the race this morning, he wanted me to tell you that he wants to run it with you next year."),
        .reply("message-sends-love", .negative, them: [worried],
               you: "My wife sends her love, she said to tell you that she is thinking of your dad and she hopes he is home soon."),
        .reply("pure-commiseration", .negative, them: [worried],
               you: "I'm so sorry to hear that, I hope he gets better soon, I'll be thinking of him and your whole family this week."),
        .reply("commiseration-and-accommodation", .negative, them: [worried],
               you: "I am so sorry to hear that, take your time with the review, we can push it to next week, no stress at all."),
        .reply("help-offer", .negative, them: [engaged],
               you: "That is wonderful news, let me know if you need anything for the wedding, I am happy to help with the planning."),
        .reply("well-wishes", .negative, them: [marathon],
               you: "Fingers crossed for your next one, I hope the recovery goes well and your legs feel better by the weekend."),
        .reply("empathy-about-them", .negative, them: [marathon],
               you: "That is amazing, you must be so proud of yourself, I bet your family was cheering for you the whole way home."),
        .reply("ack-then-ask", .negative, them: [moved],
               you: "Congrats, that's great news! How did the move go, are you all settled in now and is the new place close to work?"),
        .reply("relate-then-ask", .negative, them: [moved],
               you: "Same thing happened to me last year, it took me weeks. How did the move go in the end, are you settled in yet?"),
        .reply("moved-on-standup", .negative, them: [lake, "Great, let's start the standup. Sam, you go first."], you: workUpdate),
        .reply("name-only-redirect", .negative, them: [lake, "Okay, Sam."], you: workUpdate),
        .reply("invited-to-share", .negative,
               them: ["I finally ran my first half marathon on Sunday and I was so nervous, have you ever run one?"],
               you: "Oh nice, that reminds me of when I did a long charity bike ride last spring, I was exhausted for days and my legs were sore the whole week."),
        .reply("work-exchange", .negative, them: ["The release is scheduled for Thursday and the test plan is signed off."],
               you: "Great, I will update the checklist and send the release notes to the team after lunch, then I will close my tickets."),
    ]

    public static var cases: [Case] { positives + negatives }
}
