-- [[3],[5],[7],[9],[11]]

a = [x|x <- [3..11], odd x]

-- [(5,False),(20,True),(25,False)]
-- b = [(a, odd b) | a <- [5, 20, 25], b <- [2..4]]
