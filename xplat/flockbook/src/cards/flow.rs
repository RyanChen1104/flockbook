//! The question card's answers in progress: pure state, so keys and clicks share one path and a test can drive it
//! (port of Swift `QuestionFlow`).

use herdr_core::{Question, QuestionAnswer};

#[derive(Debug, Clone, PartialEq)]
pub struct Flow {
    pub questions: Vec<Question>,
    /// Every question's header from Claude's picker tab bar (empty for log items). More headers than questions: the rest
    /// are not read.
    pub headers: Vec<String>,
    pub step: usize,
    pub picks: Vec<Vec<usize>>,
    pub other: Vec<String>,
    /// The highlighted row (arrow keys). `options.len()` is the "Other" row.
    pub cursor: usize,
    /// The arrow keys moved the highlight (else no row is highlighted).
    pub moved: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Digit {
    Picked,
    Other,
    Ignored,
}

impl Flow {
    pub fn new(questions: &[Question], headers: &[String]) -> Flow {
        Flow {
            questions: questions.to_vec(),
            headers: headers.to_vec(),
            step: 0,
            picks: questions.iter().map(|_| Vec::new()).collect(),
            other: questions.iter().map(|_| String::new()).collect(),
            cursor: 0,
            moved: false,
        }
    }

    pub fn question(&self) -> &Question {
        &self.questions[self.step]
    }
    /// Questions in all, read or not.
    pub fn total(&self) -> usize {
        self.questions.len().max(self.headers.len())
    }
    pub fn is_last(&self) -> bool {
        self.step + 1 == self.total()
    }
    /// Some questions are known only by their header: this card cannot answer them.
    pub fn unread(&self) -> usize {
        self.total() - self.questions.len()
    }
    /// The header chip: the question's own, else the tab bar's.
    pub fn header(&self) -> &str {
        let q = self.question();
        if q.header.is_empty() {
            self.headers.get(self.step).map(String::as_str).unwrap_or("")
        } else {
            &q.header
        }
    }
    pub fn other_text(&self) -> &str {
        self.other[self.step].trim()
    }
    /// The current question has a pick or an "Other" answer.
    pub fn valid(&self) -> bool {
        !self.picks[self.step].is_empty() || !self.other_text().is_empty()
    }
    /// Number key of the "Other" row (single choice): the one after the last option.
    pub fn other_key(&self) -> usize {
        self.question().options.len() + 1
    }
    pub fn picked(&self, i: usize) -> bool {
        self.picks[self.step].contains(&i)
    }

    /// 1..=n picks option n (toggles in multi select); n+1 goes to "Other" in single choice.
    pub fn digit(&mut self, n: usize) -> Digit {
        if (1..=self.question().options.len()).contains(&n) {
            self.pick(n - 1);
            return Digit::Picked;
        }
        if n == self.other_key() && !self.question().multi_select {
            return Digit::Other;
        }
        Digit::Ignored
    }

    pub fn pick(&mut self, i: usize) {
        if i >= self.question().options.len() {
            return;
        }
        self.cursor = i;
        let step = self.step;
        if self.question().multi_select {
            if let Some(at) = self.picks[step].iter().position(|p| *p == i) {
                self.picks[step].remove(at);
            } else {
                self.picks[step].push(i);
            }
        } else {
            self.picks[step] = vec![i];
            self.other[step].clear();
        }
    }

    /// Typing an "Other" answer in single choice replaces the pick.
    pub fn set_other(&mut self, s: &str) {
        self.other[self.step] = s.to_string();
        if !self.question().multi_select && !s.trim().is_empty() {
            self.picks[self.step].clear();
        }
    }

    /// Moves the highlight by `d` rows (options, then "Other"). Single choice picks the row it lands on, like a radio list.
    /// Returns true when it landed on the "Other" row.
    pub fn move_cursor(&mut self, d: i32) -> bool {
        let n = self.question().options.len();
        self.moved = true;
        let to = (self.cursor as i32 + d).clamp(0, n as i32) as usize;
        self.cursor = to;
        if to < n {
            if !self.question().multi_select {
                self.pick(to);
            }
            false
        } else {
            true
        }
    }

    /// Return: next question, or true when the last one is answered (time to send).
    pub fn advance(&mut self) -> bool {
        if !self.valid() {
            return false;
        }
        if self.is_last() {
            return true;
        }
        if self.step + 1 >= self.questions.len() {
            return false;
        }
        self.step += 1;
        self.cursor = 0;
        false
    }

    pub fn back(&mut self) {
        if self.step > 0 {
            self.step -= 1;
            self.cursor = 0;
        }
    }

    /// What `herdr_core::question::steps` takes: 0-based picks in option order and the "Other" text if any.
    pub fn values(&self) -> Vec<QuestionAnswer> {
        (0..self.questions.len())
            .map(|k| {
                let mut picks = self.picks[k].clone();
                picks.sort_unstable();
                let o = self.other[k].trim();
                QuestionAnswer { picks, other: (!o.is_empty()).then(|| o.to_string()) }
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use herdr_core::QOption;

    fn q(multi: bool) -> Question {
        Question::new("H", "Pick?", vec![QOption::new("a"), QOption::new("b"), QOption::new("c")], multi)
    }

    #[test]
    fn single_choice_replaces_and_other_clears_picks() {
        let mut f = Flow::new(&[q(false)], &[]);
        assert!(!f.valid());
        assert_eq!(f.digit(2), Digit::Picked);
        assert_eq!(f.digit(1), Digit::Picked);
        assert_eq!(f.picks[0], vec![0]);
        assert_eq!(f.digit(4), Digit::Other);
        assert_eq!(f.digit(5), Digit::Ignored);
        f.set_other("mine");
        assert!(f.picks[0].is_empty() && f.valid());
        f.pick(1);
        assert!(f.other[0].is_empty());
    }

    #[test]
    fn multi_toggles_and_has_no_other_digit() {
        let mut f = Flow::new(&[q(true)], &[]);
        f.digit(1);
        f.digit(3);
        f.digit(1);
        assert_eq!(f.picks[0], vec![2]);
        assert_eq!(f.digit(4), Digit::Ignored);
    }

    #[test]
    fn arrows_move_and_pick_in_single_choice() {
        let mut f = Flow::new(&[q(false)], &[]);
        assert!(!f.move_cursor(1));
        assert_eq!(f.picks[0], vec![1]);
        assert!(!f.move_cursor(1));
        assert!(f.move_cursor(1), "third step lands on Other");
        assert_eq!(f.picks[0], vec![2], "landing on Other keeps the pick until text is typed");
        let mut m = Flow::new(&[q(true)], &[]);
        m.move_cursor(1);
        assert!(m.picks[0].is_empty(), "multi select only moves the highlight");
    }

    #[test]
    fn two_questions_advance_then_send() {
        let mut f = Flow::new(&[q(false), q(false)], &[]);
        assert!(!f.advance());
        f.digit(1);
        assert!(!f.advance());
        assert_eq!(f.step, 1);
        f.digit(2);
        assert!(f.advance());
        assert_eq!(f.values().len(), 2);
    }
}
