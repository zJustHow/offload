import Foundation

/// A small, hand-written, bilingual (English/Chinese) personal-data corpus with labelled queries.
///
/// It is **synthetic and written by the same author as the retrieval code**, so it is a regression
/// harness and a way to compare configurations against each other — not a benchmark, and absolute
/// numbers should not be read as real-world accuracy. It deliberately contains the situations that
/// separate the retrievers: identifiers (where embeddings fail), paraphrases with little word
/// overlap (where BM25 fails), Chinese text, distractors that share vocabulary with the answer,
/// and cross-language queries (which per-language embedders cannot answer at all).
public enum EvalCorpus {
    public struct Doc: Sendable { public let id: String; public let text: String }

    public enum Category: String, Sendable, CaseIterable { case keyword, paraphrase, identifier, crossLingual }

    public struct Query: Sendable {
        public let text: String
        public let relevant: Set<String>
        public let category: Category
    }

    public static let docs: [Doc] = [
        // --- topic: apartment lease
        Doc(id: "lease_en", text: "Signed the lease for the Mission Street apartment with landlord Mr. Alvarez. Rent is $3,400 a month and I put down a security deposit equal to two months of rent. The lease runs twelve months starting June 1."),
        Doc(id: "lease_zh", text: "昨天在上海和王先生签了租房合同,押金两个月房租,每月租金五千元,租期一年,从七月一号开始。房子在浦东新区世纪大道附近。"),
        // --- topic: child's school
        Doc(id: "school_en", text: "Mia moves up to second grade this fall. She attends Lincoln Elementary on Oak Street and morning drop-off is at 8:15 with the crossing guard on the corner. Pickup is 3:10."),
        Doc(id: "school_zh", text: "小明下学期转入清华附小三年级,每天早上七点四十分到校,下午四点半放学,家长需要在校门口接。"),
        // --- topic: flights
        Doc(id: "flight_en", text: "Booked flight UA 837 from SFO to Shanghai Pudong on March 3, window seat, confirmation code K7P2QX. Return on March 21 with a layover in Tokyo."),
        Doc(id: "flight_zh", text: "订了三月三号上海飞旧金山的东航航班,订单号 MU-882913,靠窗座位,托运行李两件。"),
        // --- topic: startup fundraising
        Doc(id: "fund_en", text: "Acme Series A update: Orion Capital sent a term sheet, eight million dollars at a thirty-two million pre-money valuation. Waiting on legal to review the liquidation preference clause."),
        Doc(id: "fund_zh", text: "Acme 的 A 轮融资有进展:猎户座资本给了投资意向书,估值三千二百万美元,正在等律师审核清算优先权条款。"),
        // --- topic: health insurance
        Doc(id: "ins_en", text: "Blue Shield PPO plan, member ID XJK0048821. Specialist copay is thirty dollars and the annual deductible is fifteen hundred. Open enrollment ends December 15."),
        Doc(id: "ins_zh", text: "平安医疗保险,保单号 PA20250719,门诊报销百分之八十,住院不设免赔额,每年一月续保。"),
        // --- topic: car
        Doc(id: "car_en", text: "The Honda Civic is due for an oil change at fifty-two thousand miles. I usually take it to Mike's Auto on Fifth Avenue, they also rotate the tires."),
        Doc(id: "car_zh", text: "本田雅阁每五千公里做一次保养,常去的四S店在浦东,上次换了机油和空气滤芯。"),
        // --- topic: cooking
        Doc(id: "cook_en", text: "Sourdough recipe: 500 grams flour, 350 grams water, 100 grams active starter and 10 grams salt. Bulk ferment about five hours, then shape and proof overnight in the fridge."),
        Doc(id: "cook_zh", text: "红烧肉的做法:五花肉切块焯水,冰糖小火炒出糖色,加酱油料酒,小火慢炖一个小时,最后大火收汁。"),
        // --- topic: recurring meeting
        Doc(id: "sync_en", text: "Weekly sync with Priya every Tuesday at 10am to go over the data pipeline migration. Action items go into the shared tracker afterwards."),
        Doc(id: "sync_zh", text: "每周二上午十点和王磊开例会,同步数据管道迁移的进度,会后把待办事项记到共享表格里。"),
        // --- topic: taxes
        Doc(id: "tax_en", text: "Third quarter estimated tax payment of $4,200 is due September 15. Pay through IRS Direct Pay and keep the confirmation number for the accountant."),
        Doc(id: "tax_zh", text: "个税汇算清缴六月三十日截止,专项附加扣除里要填子女教育和住房租金,材料交给会计。"),
        // --- topic: trip
        Doc(id: "trip_en", text: "Japan trip in April: three nights in Kyoto at a ryokan with an onsen, then two nights in Osaka. Need to reserve the Shinkansen seats a month ahead."),
        Doc(id: "trip_zh", text: "四月去日本旅行,京都住三晚温泉旅馆,大阪住两晚,新干线车票要提前一个月预订。"),
        // --- topic: fitness
        Doc(id: "gym_en", text: "Training plan: back squat five by five on Monday, bench on Wednesday, a ten kilometer run on Saturday. Deload every fourth week."),
        Doc(id: "gym_zh", text: "健身计划:周一深蹲,周三卧推,周六跑十公里,每四周减一次量。"),
        // --- topic: reading
        Doc(id: "book_en", text: "Reading Designing Data-Intensive Applications, currently on chapter seven about transactions and isolation levels. Taking notes on snapshot isolation."),
        Doc(id: "book_zh", text: "正在读《黑天鹅》,看到第三章,讲的是极端斯坦和平均斯坦的区别,打算读完再看《反脆弱》。"),

        // --- distractors that share vocabulary with the answers above
        Doc(id: "d_carlease", text: "Car lease return checklist: schedule the inspection, clean the interior, and bring both keys. Excess mileage is charged per mile over the allowance."),
        Doc(id: "d_bank", text: "Made a deposit of $1,200 at the bank branch on Market Street and asked about the savings account interest rate for the new year."),
        Doc(id: "d_school_fish", text: "Watched a documentary about a school of fish moving in formation; the narrator explained how each fish reacts to its neighbors."),
        Doc(id: "d_stairs", text: "A long flight of stairs leads up to the old library, and the reading room on the top floor has a view over the river."),
        Doc(id: "d_orion", text: "Orion is visible in the winter sky; the three stars of the belt line up with Sirius, best seen away from city lights."),
        Doc(id: "d_insurance_car", text: "Car insurance renewal quote came in higher than last year. The agent suggested raising the deductible to lower the premium."),
        Doc(id: "d_recipe_pasta", text: "Pasta carbonara: guanciale, pecorino, eggs and black pepper. Never add cream; toss off the heat so the eggs do not scramble."),
        Doc(id: "d_meeting_other", text: "Quarterly planning meeting moved to Thursday afternoon. Bring the roadmap deck and the headcount proposal."),
        Doc(id: "d_zh_rent", text: "朋友在北京租房,中介收了一个月房租的服务费,押金还没有退,房东一直拖着。"),
        Doc(id: "d_zh_school", text: "学校的食堂换了新的承包商,中午的菜品比以前丰富,家长委员会提了几条意见。"),
        Doc(id: "d_zh_flight", text: "高铁从上海到北京只要四个半小时,比飞机省去了安检和候机的时间。"),
        Doc(id: "d_zh_health", text: "最近在调整作息,每天十一点前睡觉,早上起来喝一杯温水,体检报告里血压略高。"),
        Doc(id: "d_zh_invest", text: "看了一篇关于风险投资行业的文章,讲的是估值泡沫和退出周期,作者认为今年的融资会更谨慎。"),
        Doc(id: "d_generic1", text: "Grocery list: oat milk, eggs, spinach, lemons, olive oil, coffee beans, and something for dinner on Friday."),
        Doc(id: "d_generic2", text: "Ideas for the weekend: farmers market in the morning, then maybe the new exhibit at the museum if the weather holds."),
        Doc(id: "d_generic3", text: "周末打算整理一下书房,把旧书捐掉,顺便把电脑里的照片备份到硬盘。"),
    ]

    public static let queries: [Query] = [
        // keyword: the query shares words with the answer
        Query(text: "Orion Capital term sheet", relevant: ["fund_en"], category: .keyword),
        Query(text: "Mike's Auto oil change", relevant: ["car_en"], category: .keyword),
        Query(text: "sourdough starter hydration", relevant: ["cook_en"], category: .keyword),
        Query(text: "Priya Tuesday sync", relevant: ["sync_en"], category: .keyword),
        Query(text: "Kyoto ryokan Osaka", relevant: ["trip_en"], category: .keyword),
        Query(text: "猎户座资本 投资意向书", relevant: ["fund_zh"], category: .keyword),
        Query(text: "红烧肉 糖色", relevant: ["cook_zh"], category: .keyword),
        Query(text: "清华附小 到校时间", relevant: ["school_zh"], category: .keyword),
        Query(text: "温泉旅馆 京都", relevant: ["trip_zh"], category: .keyword),
        Query(text: "例会 数据管道", relevant: ["sync_zh"], category: .keyword),
        Query(text: "Acme 的融资进展", relevant: ["fund_zh", "fund_en"], category: .keyword),

        // paraphrase: little lexical overlap; needs meaning
        Query(text: "how much did I put down when I rented the flat", relevant: ["lease_en"], category: .paraphrase),
        Query(text: "where does my daughter go to class and when do I drop her off", relevant: ["school_en"], category: .paraphrase),
        Query(text: "what are the terms of the investment offer for my company", relevant: ["fund_en"], category: .paraphrase),
        Query(text: "what do I owe the government this quarter", relevant: ["tax_en"], category: .paraphrase),
        Query(text: "what exercises am I supposed to do on which days", relevant: ["gym_en"], category: .paraphrase),
        Query(text: "what am I studying about databases right now", relevant: ["book_en"], category: .paraphrase),
        Query(text: "我租的房子每个月多少钱", relevant: ["lease_zh"], category: .paraphrase),
        Query(text: "孩子几点上学放学", relevant: ["school_zh"], category: .paraphrase),
        Query(text: "看病能报销多少", relevant: ["ins_zh"], category: .paraphrase),
        Query(text: "车多久要去做一次维护", relevant: ["car_zh"], category: .paraphrase),
        Query(text: "今年的税什么时候要弄完", relevant: ["tax_zh"], category: .paraphrase),
        Query(text: "最近在看什么书", relevant: ["book_zh"], category: .paraphrase),
        Query(text: "每周几练什么动作", relevant: ["gym_zh"], category: .paraphrase),

        // identifier: exact strings that neither word segmentation nor embeddings capture reliably
        Query(text: "K7P2QX", relevant: ["flight_en"], category: .identifier),
        Query(text: "confirmation code K7P2QX", relevant: ["flight_en"], category: .identifier),
        Query(text: "member ID XJK0048821", relevant: ["ins_en"], category: .identifier),
        Query(text: "MU-882913", relevant: ["flight_zh"], category: .identifier),
        Query(text: "订单号 MU-882913 的航班", relevant: ["flight_zh"], category: .identifier),
        Query(text: "PA20250719", relevant: ["ins_zh"], category: .identifier),
        Query(text: "保单号 PA20250719", relevant: ["ins_zh"], category: .identifier),
        Query(text: "\"liquidation preference\"", relevant: ["fund_en"], category: .identifier),
        Query(text: "$4,200", relevant: ["tax_en"], category: .identifier),

        // cross-lingual: the answer is in the other language. Per-language embedders cannot do this;
        // only a multilingual embedder (e.g. a bge-m3 endpoint) can. Reported separately.
        Query(text: "rental deposit amount for my apartment in Shanghai", relevant: ["lease_zh", "lease_en"], category: .crossLingual),
        Query(text: "孩子在哪所学校上学", relevant: ["school_zh", "school_en"], category: .crossLingual),
        Query(text: "my insurance reimbursement percentage", relevant: ["ins_zh", "ins_en"], category: .crossLingual),
        Query(text: "日本旅行的住宿安排", relevant: ["trip_zh", "trip_en"], category: .crossLingual),
    ]
}
