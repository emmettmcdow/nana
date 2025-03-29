# For generating "correct" tokenizations for testing 

from json import dumps
import sys
from transformers import BertTokenizerFast

def clean_list(input_list): 
    return "".join([ x for x in str(input_list) if x not in (" ", "[", "]") ])


assert(len(sys.argv) == 2)

tokenizer = BertTokenizerFast.from_pretrained("./")
encoded = tokenizer(sys.argv[1], 
                    max_length=16, 
                    padding="max_length", 
                    truncation=True)

print("\n".join([clean_list(encoded["input_ids"]),
                 clean_list(encoded["attention_mask"]),
                 clean_list(encoded["token_type_ids"])]))
