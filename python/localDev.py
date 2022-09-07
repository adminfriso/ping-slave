while 1:
    try:
        com = raw_input("s/i/h/w/e/c/p,file,volume(,time)>")
        comWords = com.split(",")
    except Exception as e:
        print(e)
