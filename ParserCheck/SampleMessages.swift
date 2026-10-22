import Foundation

/// The parser's test suite. Every real SMS that was misread goes in here,
/// with what it should have produced, before the patterns are touched.
struct SampleMessage {
    var label: String
    var sender: String
    var text: String
    var expect: Expectation

    enum Expectation {
        case payment(amount: Double, currency: String = "INR", merchant: String?,
                     reference: String? = nil, instrument: String? = nil,
                     direction: ParsedPayment.Direction = .debit)
        case ignored(ParseRejection)
    }
}

enum SampleMessages {
    static let all: [SampleMessage] = [

        // MARK: Banks — UPI debits

        SampleMessage(
            label: "HDFC UPI debit",
            sender: "AD-HDFCBK",
            text: "Sent Rs.486.00 From HDFC Bank A/C x1234 To UBER INDIA On 12/10/25 Ref 528512345678 Not You? Call 18002586161",
            expect: .payment(amount: 486, merchant: "Uber India",
                             reference: "528512345678", instrument: "UPI · A/c ••1234")
        ),
        SampleMessage(
            label: "ICICI UPI debit, payee after semicolon",
            sender: "AD-ICICIB",
            text: "ICICI Bank Acct XX678 debited for Rs 1250.00 on 11-Oct-25; MAKEMYTRIP credited. UPI:528498765432. Call 18002662 for dispute.",
            expect: .payment(amount: 1250, merchant: "Makemytrip",
                             reference: "528498765432", instrument: "UPI · A/c ••678")
        ),
        SampleMessage(
            label: "Axis UPI P2M block",
            sender: "AX-AxisBk",
            text: "INR 240.00 debited from A/c no. XX9012 on 12-10-25. Info: UPI/P2M/528512349999/RAPIDO. Avl Bal INR 15,320.44 - Axis Bank",
            expect: .payment(amount: 240, merchant: "Rapido",
                             reference: "528512349999", instrument: "UPI · A/c ••9012")
        ),
        SampleMessage(
            label: "SBI UPI debit",
            sender: "AD-SBIUPI",
            text: "Dear UPI user A/C X3456 debited by 150.0 on date 12Oct25 trf to IRCTC Refno 528587654321. If not u? call 1800111109. -SBI",
            expect: .payment(amount: 150, merchant: "Irctc",
                             reference: "528587654321", instrument: "UPI · A/c ••3456")
        ),
        SampleMessage(
            label: "Kotak UPI with VPA payee",
            sender: "AD-KOTAKB",
            text: "Sent Rs.320.00 from Kotak Bank AC X7788 to swiggy@okicici on 12-10-25.UPI Ref 528512340000. Not you, kotak.com/fraud",
            expect: .payment(amount: 320, merchant: "Swiggy",
                             reference: "528512340000", instrument: "UPI · A/c ••7788")
        ),

        // MARK: Cards

        SampleMessage(
            label: "HDFC credit card spend",
            sender: "AD-HDFCBK",
            text: "Spent Rs.4520.00 On HDFC Bank Card 4455 At INDIGO AIRLINES On 2025-10-10. Avl Lmt INR 95,480. Not you? Call 18002586161",
            expect: .payment(amount: 4520, merchant: "Indigo Airlines", instrument: "Card ••4455")
        ),
        SampleMessage(
            label: "Foreign currency card spend",
            sender: "AD-ICICIB",
            text: "Your ICICI Bank Credit Card XX3321 has been used for a transaction of USD 42.50 on 09-Oct-25 at MARRIOTT SINGAPORE. Info: Txn ID 884421900233.",
            expect: .payment(amount: 42.50, currency: "USD", merchant: "Marriott Singapore",
                             reference: "884421900233", instrument: "Card ••3321")
        ),
        SampleMessage(
            label: "Amount with rupee symbol, no space",
            sender: "VM-AXISBK",
            text: "₹1,899.00 spent on Axis Bank Card XX2210 at OYO ROOMS on 11-10-25. Not you? Block card at axisbank.com",
            expect: .payment(amount: 1899, merchant: "Oyo Rooms", instrument: "Card ••2210")
        ),

        // MARK: Other rails

        SampleMessage(
            label: "NEFT transfer",
            sender: "AD-SBIINB",
            text: "Your A/c XX3456 is debited by Rs.12,500.00 on 10-Oct-25 by NEFT to TAJ HOTELS. UTR SBIN425123456789. -SBI",
            expect: .payment(amount: 12500, merchant: "Taj Hotels",
                             reference: "SBIN425123456789", instrument: "NEFT · A/c ••3456")
        ),
        SampleMessage(
            label: "FASTag wallet debit",
            sender: "AD-FASTAG",
            text: "Rs.85.00 debited from your ICICI FASTag wallet at MUMBAI PUNE TOLL PLAZA on 12-Oct-25. Txn ID 773312009988.",
            expect: .payment(amount: 85, merchant: "Mumbai Pune Toll Plaza",
                             reference: "773312009988")
        ),
        SampleMessage(
            label: "Amount written after the number",
            sender: "AD-IDFCFB",
            text: "750.00 INR debited from IDFC FIRST Bank A/c XX5566 towards HPCL FUEL STATION on 12-10-25. Ref No 992211334455.",
            expect: .payment(amount: 750, merchant: "Hpcl Fuel Station",
                             reference: "992211334455", instrument: "A/c ••5566")
        ),

        // MARK: Refund

        SampleMessage(
            label: "Refund reversal",
            sender: "AD-HDFCBK",
            text: "Refund of Rs.1250.00 for your transaction at MAKEMYTRIP has been credited back to HDFC Bank Card 4455 on 13-10-25. Ref 528498765432.",
            expect: .payment(amount: 1250, merchant: "Makemytrip",
                             reference: "528498765432", instrument: "Card ••4455",
                             direction: .refund)
        ),

        // MARK: Ignore cases

        SampleMessage(
            label: "OTP",
            sender: "AD-HDFCBK",
            text: "123456 is the OTP for your transaction of Rs.4520.00 at INDIGO. Valid for 10 mins. Do not share with anyone. -HDFC Bank",
            expect: .ignored(.otp)
        ),
        SampleMessage(
            label: "Collect request",
            sender: "AD-ICICIB",
            text: "RAHUL SHARMA has requested Rs.500.00 via UPI. Approve in your UPI app by 12-Oct-25 21:00. Never approve to receive money.",
            expect: .ignored(.request)
        ),
        SampleMessage(
            label: "Failed payment",
            sender: "AD-AXISBK",
            text: "Your payment of Rs.2,400.00 to INDIGO AIRLINES has failed. The amount, if debited, will be refunded in 3 working days. -Axis Bank",
            expect: .ignored(.failed)
        ),
        SampleMessage(
            label: "Upcoming autopay debit",
            sender: "AD-HDFCBK",
            text: "Rs.199.00 will be debited from your HDFC Bank A/c XX1234 on 15-Oct-25 towards NETFLIX autopay mandate. Ensure sufficient balance.",
            expect: .ignored(.upcoming)
        ),
        SampleMessage(
            label: "Money received",
            sender: "AD-KOTAKB",
            text: "Rs.5,000.00 has been credited to your Kotak Bank A/c X7788 on 12-10-25 by RAHUL SHARMA. UPI Ref 528500001111.",
            expect: .ignored(.credit)
        ),
        SampleMessage(
            label: "Promotional offer",
            sender: "VM-ICICIB",
            text: "Congratulations! You are pre-approved for a personal loan of Rs.5,00,000 at lowest interest. Apply now at icicibank.com. T&C apply.",
            expect: .ignored(.promo)
        ),
        SampleMessage(
            label: "Balance update only",
            sender: "AD-SBIPSG",
            text: "Your A/c XX3456 has an Avl Bal of Rs.15,320.44 as on 12-Oct-25. Download YONO for a full statement. -SBI",
            expect: .ignored(.balance)
        ),
        SampleMessage(
            label: "Delivery notification with an amount",
            sender: "VM-SWIGGY",
            text: "Your order worth Rs.320 is on the way! Track it in the app.",
            expect: .ignored(.noDebitWord)
        )
    ]
}
