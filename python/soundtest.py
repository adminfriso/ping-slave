import pygame
pygame.mixer.init()
sound1=pygame.mixer.Sound("../storage/ch0.wav")
sound2=pygame.mixer.Sound("../storage/Clap.wav")
sound1.set_volume(0.1)
sound2.set_volume(0.1)
pygame.mixer.Sound.play(sound1)
pygame.mixer.Sound.play(sound2)