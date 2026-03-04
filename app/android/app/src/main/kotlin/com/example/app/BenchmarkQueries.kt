package com.example.app

data class BenchmarkQuery(
    val id: String,
    val category: String,
    val text: String,
    val wordCount: Int,
)

object BenchmarkQueries {
    val ALL: List<BenchmarkQuery> = listOf(
        // SHORT (3-7 words) — quick clinical lookups
        BenchmarkQuery("short_01", "short", "Baby continuous crying", 3),
        BenchmarkQuery("short_02", "short", "Bleeding after delivery", 3),
        BenchmarkQuery("short_03", "short", "Newborn not breathing what to do", 6),
        BenchmarkQuery("short_04", "short", "How to treat neonatal jaundice", 6),
        BenchmarkQuery("short_05", "short", "Signs of preeclampsia in pregnancy", 6),
        BenchmarkQuery("short_06", "short", "When to cut the umbilical cord", 7),
        BenchmarkQuery("short_07", "short", "Breastfeeding positions for new mothers", 6),
        BenchmarkQuery("short_08", "short", "Normal blood pressure range during pregnancy", 7),

        // MEDIUM (20-30 words) — contextual clinical questions
        BenchmarkQuery("medium_01", "medium",
            "A mother delivered two hours ago and is now bleeding heavily. " +
            "The uterus feels soft and boggy. What should I do immediately?", 22),
        BenchmarkQuery("medium_02", "medium",
            "A newborn is 3 days old with yellow skin and eyes. " +
            "The baby is breastfeeding well and active. " +
            "How do I assess if this jaundice is dangerous?", 30),
        BenchmarkQuery("medium_03", "medium",
            "A pregnant woman at 36 weeks has a blood pressure of 160 over 110 " +
            "with headache and blurred vision. What are the emergency steps?", 25),
        BenchmarkQuery("medium_04", "medium",
            "The baby was born 10 minutes ago and is not crying. " +
            "The skin is blue and the heart rate is below 100. " +
            "What resuscitation steps should I follow?", 30),
        BenchmarkQuery("medium_05", "medium",
            "A woman is in active labor and the cord has prolapsed through the cervix. " +
            "We are in a rural health center with no surgeon available. What do I do?", 28),
        BenchmarkQuery("medium_06", "medium",
            "I have a mother who delivered yesterday and now has a fever of 39 degrees, " +
            "fast pulse, and foul smelling lochia. What could this be and how should I manage it?", 29),

        // LONG (65-80 words) — full patient vignettes
        BenchmarkQuery("long_01", "long",
            "I am a midwife at a rural clinic in Zanzibar. A 28 year old woman, " +
            "gravida 4 para 3, is at 38 weeks gestation. She came to the clinic " +
            "complaining of severe headache, swelling in her hands and face, and " +
            "epigastric pain. Her blood pressure is 170 over 115. She has protein " +
            "in her urine. The nearest hospital is 2 hours away. " +
            "What should I do while waiting for transport?", 68),
        BenchmarkQuery("long_02", "long",
            "A first-time mother delivered a baby boy 6 hours ago at our health center. " +
            "The delivery was normal but the placenta took 45 minutes to deliver. " +
            "Now the mother is dizzy, pale, has a fast weak pulse of 120, and is " +
            "bleeding from the vagina with large clots. Her blood pressure has dropped " +
            "to 90 over 60. We do not have blood for transfusion. " +
            "What emergency steps should I take?", 70),
        BenchmarkQuery("long_03", "long",
            "A newborn was delivered at home by a traditional birth attendant and brought " +
            "to our clinic at 12 hours of age. The mother says the baby has not " +
            "breastfed since birth and is breathing fast. On examination the baby weighs " +
            "2.1 kilograms, temperature is 36.0 degrees, respiratory rate is 72, and " +
            "there is chest indrawing. The baby is lethargic and has poor muscle tone. " +
            "How should I manage this baby?", 71),
        BenchmarkQuery("long_04", "long",
            "I am a nurse working alone at a dispensary in a remote village. A 19 year old " +
            "woman in her first pregnancy at 32 weeks gestation comes in with severe " +
            "abdominal pain and vaginal bleeding. She says the bleeding started suddenly " +
            "one hour ago after she was carrying water. Her abdomen is rigid and tender. " +
            "The fetal heartbeat is difficult to hear. Her blood pressure is 100 over 70 " +
            "and pulse is 110. What is the likely diagnosis and what should I do?", 78),
    )
}
